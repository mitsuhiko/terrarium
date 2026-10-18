# Async data with ui.resource: a spinner while it loads, the result after.
import asyncio

import ui


async def load_quote(n):
    await asyncio.sleep(0.4)  # pretend this is a network request
    return ["Simple is better than complex.", "Readability counts.", "Now is better than never."][n % 3]


def App():
    n = ui.signal(0)
    quote = ui.resource(load_quote, n)
    return ui.Screen(
        "Async Data",
        ui.Card(
            ui.Show(quote.loading, ui.ProgressView(), fallback=ui.Text(lambda: quote() or "", font="title3")),
            ui.Button("Next quote", on_click=lambda: n.update(lambda v: v + 1), kind="tinted"),
        ),
        ui.HStack(
            ui.Text(lambda: f"{n()} clicks", font_weight="bold"),
            ui.Spacer(),
            ui.Text(lambda: "odd" if n() % 2 else "even", padding=(4, 10), corner_radius=12,
                    background=lambda: "tint" if n() % 2 else "fill", color=lambda: "white" if n() % 2 else None),
        ),
        ui.Show(quote.error, ui.Text(lambda: f"Error: {quote.error()}", color="red", font="footnote")),
    )


ui.run(App)
