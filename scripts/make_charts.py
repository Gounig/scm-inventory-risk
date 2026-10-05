"""
README 용 결과 차트 만들기 → images/*.png
실행: python scripts/make_charts.py   (먼저 run_all.py 로 scm.db 를 만들어야 함)
"""
import sqlite3
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib import font_manager

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "images"
OUT.mkdir(exist_ok=True)
con = sqlite3.connect(ROOT / "scm.db")

# ---- 스타일: 한 가지 강조색 + 회색, 얇은 막대, 옅은 축 ----
for name in ["Noto Sans CJK KR", "AppleGothic", "Malgun Gothic", "NanumGothic"]:
    if any(name in f.name for f in font_manager.fontManager.ttflist):
        plt.rcParams["font.family"] = name
        break
plt.rcParams.update({
    "figure.facecolor": "#fcfcfb", "axes.facecolor": "#fcfcfb",
    "axes.edgecolor": "#d6d5cf", "axes.labelcolor": "#52514e",
    "xtick.color": "#52514e", "ytick.color": "#0b0b0b",
    "axes.spines.top": False, "axes.spines.right": False,
    "font.size": 11, "axes.titlesize": 14, "axes.titleweight": "bold",
    "axes.titlelocation": "left", "axes.titlepad": 14,
})
BLUE, ORANGE, GRAY = "#2a78d6", "#eb6834", "#c9c8c1"
INK, MUTED = "#0b0b0b", "#52514e"


def q(sql):
    return con.execute(sql).fetchall()


def hbar(labels, values, colors, title, note, fname, fmt="{:.1f}%", xmax=None):
    fig, ax = plt.subplots(figsize=(8, 0.55 * len(labels) + 1.6), dpi=150)
    y = range(len(labels))[::-1]
    ax.barh(list(y), values, color=colors, height=0.55, edgecolor="#fcfcfb", linewidth=2)
    ax.set_yticks(list(y), labels)
    ax.tick_params(axis="y", length=0)
    ax.spines["left"].set_visible(False)
    ax.xaxis.grid(True, color="#ecebe6", linewidth=0.8)
    ax.set_axisbelow(True)
    top = xmax or max(values) * 1.18
    ax.set_xlim(0, top)
    for yi, v in zip(y, values):
        ax.text(v + top * 0.01, yi, fmt.format(v), va="center", color=INK, fontsize=10)
    ax.set_title(title, color=INK)
    fig.text(0.01, 0.01, note, color=MUTED, fontsize=9)
    fig.tight_layout(rect=(0, 0.04, 1, 1))
    fig.savefig(OUT / fname)
    plt.close(fig)
    print("→", OUT / fname)


# 1) 백카톤 원인
rows = q("""SELECT bc_cause, ROUND(100.0*COUNT(*)/SUM(COUNT(*)) OVER (),1)
            FROM bc_lines GROUP BY bc_cause ORDER BY COUNT(*) DESC""")
hbar([r[0] for r in rows], [r[1] for r in rows],
     [BLUE if r[0].startswith("A") else GRAY for r in rows],
     "백카톤은 왜 생겼을까 — 원인별 줄 비율",
     "가상 데이터 · 이전PI의 원래 선적일과 발주일·입고일을 비교해 분류", "01_bc_causes.png")

# 2) 거래처별 입고 지연율 (상위 10)
rows = q("""SELECT supplier, late_rate_pct FROM supplier_delay
            ORDER BY late_rate_pct DESC LIMIT 10""")
hbar([r[0] for r in rows], [r[1] for r in rows], [BLUE] * len(rows),
     "거래처별 입고 지연율 (상위 10)",
     "가상 데이터 · 지연율 = 입고 지연으로 빠진 줄 / (제때 실린 줄 + 빠진 줄), 10줄 이상 거래처",
     "02_supplier_delay.png", xmax=100)

# 3) 입고됐는데 누락(C) — 선적 며칠 전 입고
rows = q("""SELECT CASE WHEN gap<=2 THEN '선적 0~2일 전' WHEN gap<=7 THEN '선적 3~7일 전'
                        WHEN gap<=14 THEN '선적 8~14일 전' ELSE '선적 15일 이상 전' END,
                   COUNT(*), MIN(gap)
            FROM (SELECT CAST(JULIANDAY(missed_ship_date)-JULIANDAY(rcv_date) AS INTEGER) gap
                  FROM bc_lines WHERE bc_cause='C. 입고됐는데 누락')
            GROUP BY 1 ORDER BY 3""")
hbar([r[0] for r in rows], [r[1] for r in rows], [BLUE] * len(rows),
     "입고됐는데 안 실린 줄 — 선적 며칠 전에 들어왔나",
     "가상 데이터 · 8일 이상 전에 들어왔다면 작업 시간보다 재고 확인·배정 문제일 가능성",
     "03_missed_timing.png", fmt="{:.0f}줄")

# 4) 발주 기한 규칙 검증
rows = q("""SELECT ordered_late, ROUND(100.0*SUM(became_bc)/COUNT(*),1), COUNT(*)
            FROM order_timing GROUP BY ordered_late ORDER BY ordered_late""")
labels = [f"기한 안에 발주 ({rows[0][2]}줄)", f"기한보다 늦게 발주 ({rows[1][2]}줄)"]
fig, ax = plt.subplots(figsize=(6.5, 4.2), dpi=150)
ax.bar(labels, [r[1] for r in rows], color=[GRAY, ORANGE], width=0.5,
       edgecolor="#fcfcfb", linewidth=2)
for i, r in enumerate(rows):
    ax.text(i, r[1] + 1.2, f"{r[1]}%", ha="center", color=INK, fontsize=13, fontweight="bold")
ax.set_ylim(0, max(r[1] for r in rows) * 1.25)
ax.set_ylabel("백카톤이 된 비율 (%)")
ax.yaxis.grid(True, color="#ecebe6", linewidth=0.8)
ax.set_axisbelow(True)
ax.tick_params(axis="x", length=0)
ax.set_title("발주 기한을 넘기면 백카톤 비율이 2배 넘게 높아짐", color=INK)
fig.text(0.01, 0.01, "가상 데이터 · P80 = 거래처 물건이 10번 중 8번 들어오는 일수", color=MUTED, fontsize=9)
fig.tight_layout(rect=(0, 0.04, 1, 1))
fig.savefig(OUT / "04_order_deadline.png")
plt.close(fig)
print("→", OUT / "04_order_deadline.png")
