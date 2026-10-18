"""The Mandelbrot set: tap anywhere on it to zoom in there.

A point c belongs to the set when z = z*z + c, starting at 0, never runs
away. The colors show how quickly the points outside run away. numpy works
on all the points of the picture at once.

Turn on "Use all cores" to compute the picture in strips with a
multiprocessing Pool: each process is a Python of its own, on its own CPU
core. Turning it on takes a moment, while the processes start.
Keep the `if __name__ == "__main__":` guard: the processes import this file.
"""

import math
import os
import time

import numpy as np

PIXELS = 720  # the picture is 360 points wide, at 2 pixels per point
START = (-0.6, 0.0, 3.0)  # center (real, imaginary) and width


def escape_times(args):
    """Rows of the picture: for each point, after how many steps it ran away
    (smoothed, so the colors blend), or `limit` if it never did."""
    re_min, re_max, im_top, im_step, row0, rows, limit = args
    re = np.linspace(re_min, re_max, PIXELS)
    im = im_top - (row0 + np.arange(rows)) * im_step
    c = (re[None, :] + 1j * im[:, None]).ravel()
    z = np.zeros_like(c)
    times = np.full(c.shape, float(limit))
    alive = np.arange(c.size)  # the points that haven't run away yet
    for n in range(limit):
        z = z * z + c
        gone = z.real * z.real + z.imag * z.imag > 16
        if gone.any():
            times[alive[gone]] = n + 1 - np.log2(np.log2(np.abs(z[gone])))
            keep = ~gone
            z, c, alive = z[keep], c[keep], alive[keep]
            if not alive.size:
                break
    return times.reshape(rows, PIXELS)


def strip(args):
    """One strip of the picture, in color (what a process sends back: 3
    bytes a pixel are quicker to pass around than 8)."""
    return colorize(escape_times(args), args[-1])


def colorize(times, limit):
    """Escape times to colors: bands that cycle, black inside the set."""
    t = np.sqrt(np.maximum(times, 0)) * 0.35
    rgb = 0.5 + 0.5 * np.cos(2 * np.pi * (t[..., None] + np.array([0.0, 0.15, 0.3])))
    rgb[times >= limit] = 0
    return (rgb * 255).astype(np.uint8)


if __name__ == "__main__":
    import asyncio
    import multiprocessing as mp

    import ui
    from PIL import Image

    def Mandelbrot():
        view = ui.signal(START)
        history = []
        parallel = ui.signal(False)
        busy = ui.signal(False)
        picture = ui.signal()  # a PIL image
        info = ui.signal("")
        pool = {}

        def stop_pool():
            if "pool" in pool:
                pool.pop("pool").terminate()

        ui.on_cleanup(stop_pool)

        def render(center_re, center_im, width):
            zoom = START[2] / width
            limit = int(120 + 60 * math.log2(max(zoom, 1)))
            step = width / PIXELS
            strips = 12
            rows = PIXELS // strips
            jobs = [(center_re - width / 2, center_re + width / 2, center_im + width / 2, step, i * rows, rows, limit)
                    for i in range(strips)]
            if parallel.peek() and "pool" not in pool:
                # Start the processes (and let each one import numpy) before the clock starts.
                pool["pool"] = mp.Pool(os.cpu_count())
                pool["pool"].map(strip, [(0, 1, 0, 0, 0, 1, 1)] * 16, chunksize=1)
            start = time.perf_counter()
            if parallel.peek():
                parts = pool["pool"].map(strip, jobs, chunksize=1)
                who = f"{os.cpu_count()} processes"
            else:
                parts = [strip(job) for job in jobs]
                who = "1 process"
            image = Image.fromarray(np.vstack(parts))
            seconds = time.perf_counter() - start
            return image, f"{zoom:,.0f}x zoom · {limit} steps · {seconds:.2f} s on {who}"

        # Draw again whenever the view (or the toggle) changes. Async, so
        # "Computing…" shows before the work starts.
        @ui.effect
        def _():
            target = view()
            parallel()

            async def go():
                busy.set(True)
                await asyncio.sleep(0.05)
                image, text = render(*target)
                with ui.batch():
                    picture.set(image)
                    info.set(text)
                    busy.set(False)

            asyncio.ensure_future(go())

        def zoom_at(e):
            if busy.peek():
                return
            re, im, width = view.peek()
            history.append(view.peek())
            view.set((re + (e.x / 360 - 0.5) * width, im - (e.y / 360 - 0.5) * width, width / 4))

        def back():
            if history:
                view.set(history.pop())

        def crosshair(p):
            if busy():
                p.fill_style = "rgba(0, 0, 0, 0.35)"
                p.fill_rect(0, 0, 360, 360)
                p.text("Computing…", 180, 186, color="white", font="bold 18px system-ui", align="center")

        return ui.Screen(
            "Mandelbrot",
            ui.ZStack(
                ui.Image(picture, corner_radius=14),
                ui.Canvas(crosshair, width=360, height=360, on_pointer_down=zoom_at),
            ),
            ui.Text(info, font="footnote", color="secondary", mono=True),
            ui.HStack(
                ui.Button("Back", on_click=back, icon="arrow.uturn.backward", kind="gray", flex=1,
                          disabled=lambda: busy() or view() == START),
                ui.Button("Start over", on_click=lambda: (history.clear(), view.set(START)),
                          icon="arrow.counterclockwise", kind="gray", flex=1, disabled=lambda: view() == START),
            ),
            ui.Section(
                ui.Toggle("Use all cores", parallel),
                footer="Compute the strips of the picture in a pool of processes, one per CPU core.",
            ),
            large_title=False,
        )

    ui.run(Mandelbrot, theme="dark")
