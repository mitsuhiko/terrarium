# Plots show up right in the console.
import matplotlib.pyplot as plt
import numpy as np

x = np.linspace(0, 4 * np.pi, 200)
plt.figure(figsize=(8, 5))  # width and height in inches
plt.plot(x, np.sin(x), label="sin")
plt.plot(x, np.cos(x), label="cos")
plt.legend()
plt.title("Waves")
plt.show()
