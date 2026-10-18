# Programs can talk to the internet with requests (or urllib).
# Try another repository, or print more of the data.
import requests

repo = "python/cpython"
r = requests.get(
    f"https://api.github.com/repos/{repo}",
    headers={"User-Agent": "terrarium-example"},
    timeout=10,
)
r.raise_for_status()
info = r.json()

print(info["full_name"], "-", info["description"])
print(f"{info['stargazers_count']:,} stars, {info['forks_count']:,} forks")
print("Default branch:", info["default_branch"])
