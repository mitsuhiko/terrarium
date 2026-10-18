# Brick Breaker: clear the wall with the ball. Drag across the game to move
# the paddle, tap to launch the ball, or turn on Tilt and steer by tilting
# the phone.
#
# Uses ui.Canvas with on_frame (a game loop that runs every frame), motion
# (the tilt), sound effects and haptics. Tap × to close it.
import math
import random
from typing import Any

import haptics
import motion
import sound
import ui

W, H = 360, 560
COLS = 8
BRICK_W, BRICK_H = W / COLS, 22
TOP = 64  # where the wall starts
PADDLE_W, PADDLE_H, PADDLE_Y = 76, 12, H - 44
R = 7  # the ball's radius
COLORS = ["#ff375f", "#ff9f0a", "#ffd60a", "#30d158", "#64d2ff", "#0a84ff", "#5e5ce6", "#bf5af2"]


def wall(level):
    """The bricks of a level: more rows each level, and gaps from level 3."""
    rows = min(3 + level, 8)
    bricks = []
    for r in range(rows):
        for c in range(COLS):
            if level >= 3 and (r + c * level) % 7 == 0:
                continue
            bricks.append({"x": c * BRICK_W, "y": TOP + r * BRICK_H, "color": COLORS[r], "points": (rows - r) * 10})
    return bricks


def BrickBreaker():
    g: dict[str, Any] = {"best": 0}  # the game's state, changed every frame
    tick = ui.signal(0)  # bumped every frame, so the canvas draws again
    tilt = ui.signal(False)

    def new_game():
        g.update(score=0, lives=3, level=0, particles=[], px=W / 2)
        next_level()

    def next_level():
        g["level"] += 1
        g["bricks"] = wall(g["level"])
        serve(f"Level {g['level']} · tap to launch")

    def serve(message):
        g.update(state="ready", message=message, bx=g["px"], by=PADDLE_Y - R, vx=0.0, vy=0.0)

    def launch():
        speed = 330 + 35 * g["level"]
        angle = random.uniform(-0.5, 0.5)
        g.update(state="playing", message="", vx=speed * math.sin(angle), vy=-speed * math.cos(angle))
        sound.play_effect("jump", volume=0.3)

    def burst(x, y, color):
        for _ in range(10):
            a, v = random.uniform(0, 2 * math.pi), random.uniform(40, 160)
            g["particles"].append({"x": x, "y": y, "vx": v * math.cos(a), "vy": v * math.sin(a), "life": 1.0,
                                   "color": color})

    def bounce_off_bricks():
        bx, by = g["bx"], g["by"]
        for brick in g["bricks"]:
            x, y = brick["x"], brick["y"]
            if bx + R > x and bx - R < x + BRICK_W and by + R > y and by - R < y + BRICK_H:
                # Bounce off the side the ball went in the least.
                overlap_x = min(bx + R - x, x + BRICK_W - (bx - R))
                overlap_y = min(by + R - y, y + BRICK_H - (by - R))
                if overlap_x < overlap_y:
                    g["vx"] = -g["vx"]
                else:
                    g["vy"] = -g["vy"]
                g["bricks"].remove(brick)
                g["score"] += brick["points"]
                burst(x + BRICK_W / 2, y + BRICK_H / 2, brick["color"])
                sound.play_effect("pop", volume=0.4, pitch=random.uniform(0.9, 1.2))
                return

    def move_ball(dt):
        # Small steps, so a fast ball can't jump over a brick.
        speed = math.hypot(g["vx"], g["vy"])
        steps = max(1, math.ceil(speed * dt / (R / 2)))
        for _ in range(steps):
            g["bx"] += g["vx"] * dt / steps
            g["by"] += g["vy"] * dt / steps
            if g["bx"] < R or g["bx"] > W - R:
                g["vx"] = -g["vx"]
                g["bx"] = min(max(g["bx"], R), W - R)
            if g["by"] < TOP - 20 + R:
                g["vy"] = abs(g["vy"])
            # The paddle: where the ball hits it sets the angle it leaves at.
            off = (g["bx"] - g["px"]) / (PADDLE_W / 2)
            if g["vy"] > 0 and PADDLE_Y <= g["by"] + R <= PADDLE_Y + PADDLE_H and abs(off) <= 1.15:
                angle = max(-1, min(1, off)) * math.radians(60)
                g["vx"], g["vy"] = speed * math.sin(angle), -speed * math.cos(angle)
                haptics.impact("light")
                sound.play_effect("click", volume=0.3)
            bounce_off_bricks()

    def step(dt):
        if tilt.peek():
            g["px"] += motion.get_gravity()[0] * 1400 * dt
        g["px"] = min(max(g["px"], PADDLE_W / 2), W - PADDLE_W / 2)
        if g["state"] == "ready":
            g["bx"] = g["px"]
        elif g["state"] == "playing":
            move_ball(dt)
            if not g["bricks"]:
                sound.play_effect("powerup")
                haptics.notification("success")
                next_level()
            elif g["by"] > H + R:
                g["lives"] -= 1
                haptics.notification("error")
                if g["lives"] == 0:
                    sound.play_effect("explosion")
                    g["best"] = max(g["best"], g["score"])
                    g.update(state="over", message="Game over · tap to play again")
                else:
                    sound.play_effect("error", volume=0.4)
                    serve("Tap to launch")
        for p in g["particles"]:
            p["x"] += p["vx"] * dt
            p["y"] += p["vy"] * dt
            p["vy"] += 300 * dt
            p["life"] -= 1.5 * dt
        g["particles"] = [p for p in g["particles"] if p["life"] > 0]
        tick.set(tick.peek() + 1)

    def draw(p):
        tick()  # read it, so every frame draws again
        p.clear("#0d1117")
        p.text(f"{g['score']}", 14, 34, color="white", font="bold 22px system-ui")
        p.text(f"Level {g['level']}" + (f" · best {g['best']}" if g["best"] else ""), W / 2, 32, color="#8b949e",
               font="15px system-ui", align="center")
        p.text("♥" * g["lives"], W - 14, 33, color="#ff375f", font="18px system-ui", align="right")
        # One path per color: fewer commands for the renderer.
        for color in COLORS:
            p.begin_path()
            for b in g["bricks"]:
                if b["color"] == color:
                    p.round_rect(b["x"] + 2, b["y"] + 2, BRICK_W - 4, BRICK_H - 4, 5)
            p.fill_style = color
            p.fill()
        for q in g["particles"]:
            p.global_alpha = max(0, q["life"])
            p.circle(q["x"], q["y"], 2.5, fill=q["color"])
        p.global_alpha = 1
        p.begin_path()
        p.round_rect(g["px"] - PADDLE_W / 2, PADDLE_Y, PADDLE_W, PADDLE_H, 6)
        p.fill_style = "#e6edf3"
        p.fill()
        if g["state"] != "over":
            p.circle(g["bx"], g["by"], R, fill="white")
        if g["message"]:
            p.text(g["message"], W / 2, H / 2 + 60, color="white", font="bold 20px system-ui", align="center")

    def pointer_down(e):
        if g["state"] == "over":
            new_game()
        elif g["state"] == "ready":
            if not tilt.peek():
                g["px"] = e.x
            launch()
        elif not tilt.peek():
            g["px"] = e.x

    def pointer_move(e):
        if not tilt.peek():
            g["px"] = e.x

    @ui.effect
    def _():
        if tilt():
            motion.start_updates()
            ui.on_cleanup(motion.stop_updates)  # when Tilt goes off again, or the app closes

    new_game()
    return ui.Screen(
        "Brick Breaker",
        ui.Canvas(draw, width=W, height=H, on_frame=step, on_pointer_down=pointer_down, on_pointer_move=pointer_move,
                  corner_radius=16),
        ui.Section(ui.Toggle("Tilt to steer", tilt)),
        large_title=False,
    )


ui.run(BrickBreaker, theme="dark")
