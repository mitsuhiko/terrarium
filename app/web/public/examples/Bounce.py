# A tiny game loop: on_frame runs every animation frame with the time step.
import random

import ui

W, H = 360, 480


def new_ball():
    return {"x": random.uniform(20, W - 20), "y": random.uniform(20, H / 2), "vx": random.uniform(-150, 150),
            "vy": 0.0, "r": random.uniform(8, 22), "color": random.choice(["#ff3b30", "#ff9500", "#34c759", "#007aff", "#af52de"])}


balls = ui.signal([new_ball() for _ in range(8)])
fps = ui.signal(0.0)


def step(dt):
    for b in balls():
        b["vy"] += 900 * dt
        b["x"] += b["vx"] * dt
        b["y"] += b["vy"] * dt
        if b["y"] > H - b["r"]:
            b["y"], b["vy"] = H - b["r"], -abs(b["vy"]) * 0.85
        if not b["r"] < b["x"] < W - b["r"]:
            b["vx"] = -b["vx"]
            b["x"] = min(max(b["x"], b["r"]), W - b["r"])
    balls.set(balls())  # mutated in place: tell readers it changed
    fps.set(round(0.9 * fps() + 0.1 / max(dt, 1e-3), 1))


def draw(p):
    p.clear("#101418")
    for b in balls():
        p.circle(b["x"], b["y"], b["r"], fill=b["color"])
    p.text(f"{fps():.0f} fps · tap to add", 12, 24, color="#ffffffaa", font="15px system-ui, sans-serif")


def tap(e):
    b = new_ball()
    b["x"], b["y"] = e.x, e.y
    balls.update(lambda bs: bs + [b])


ui.run(ui.Screen("Bounce", ui.Canvas(draw, width=W, height=H, on_frame=step, on_pointer_down=tap)))
