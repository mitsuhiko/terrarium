// The coding agent's App Store screenshot (`agent=demo` launch hook): the
// model's turns are scripted (pi-ai's faux provider), the tools are real.
// They read, edit, check and run Examples/Plot.py.

export const DEMO_PROMPT = "Add a damped sine wave to the plot and label the axes";

export async function demoScript(file = "Plot.py") {
  const { fauxAssistantMessage, fauxText, fauxToolCall } = await import("@earendil-works/pi-ai/providers/faux");
  const step = (text: string | null, name: string, args: Parameters<typeof fauxToolCall>[1], id: string) =>
    fauxAssistantMessage([...(text ? [fauxText(text)] : []), fauxToolCall(name, args, { id })], { stopReason: "toolUse" });
  return [
    step("I'll look at the plot first.", "read", { path: file }, "read"),
    step(
      "It draws sin and cos over two periods. I'll add a sine that fades out, then the axis labels.",
      "edit",
      {
        path: file,
        edits: [
          {
            oldText: 'plt.plot(x, np.cos(x), label="cos")\n',
            newText: 'plt.plot(x, np.cos(x), label="cos")\nplt.plot(x, np.exp(-x / 5) * np.sin(x), label="damped")\n',
          },
          { oldText: "plt.legend()\n", newText: 'plt.xlabel("x")\nplt.ylabel("y")\nplt.legend()\n' },
        ],
      },
      "edit",
    ),
    step(null, "check", { paths: [file] }, "check"),
    step(null, "run_python", { path: file }, "run"),
    fauxAssistantMessage([
      fauxText(
        "Done. Plot.py now draws a third curve, **damped**: `e^(-x/5) · sin(x)`, a sine wave that fades out. " +
          "The axes are labeled *x* and *y*.\n\n" +
          "I ran it to make sure the figure renders, and ruff and ty find no problems. Tap ▶ to see the new plot.",
      ),
    ]),
  ];
}
