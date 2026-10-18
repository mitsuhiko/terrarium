# The weather where you are, or anywhere: now, the next 24 hours and the
# week. Search for a city, or tap the location button.
#
# Uses location (where you are), httpx to ask Open-Meteo (a free weather
# service without sign-up) and ui.resource, which loads in the background
# and loads again when the place or the units change. Tap × to close it.
import datetime as dt

import httpx
import location
import ui

FORECAST = "https://api.open-meteo.com/v1/forecast"
GEOCODING = "https://geocoding-api.open-meteo.com/v1/search"
FALLBACK = {"name": "Vienna", "lat": 48.2082, "lon": 16.3738}

# WMO weather codes: (description, SF Symbol by day, by night)
CODES = {
    0: ("Clear", "sun.max.fill", "moon.stars.fill"),
    1: ("Mostly clear", "sun.min.fill", "moon.fill"),
    2: ("Partly cloudy", "cloud.sun.fill", "cloud.moon.fill"),
    3: ("Overcast", "cloud.fill", "cloud.fill"),
    45: ("Fog", "cloud.fog.fill", "cloud.fog.fill"),
    48: ("Freezing fog", "cloud.fog.fill", "cloud.fog.fill"),
    51: ("Light drizzle", "cloud.drizzle.fill", "cloud.drizzle.fill"),
    53: ("Drizzle", "cloud.drizzle.fill", "cloud.drizzle.fill"),
    55: ("Heavy drizzle", "cloud.drizzle.fill", "cloud.drizzle.fill"),
    56: ("Freezing drizzle", "cloud.sleet.fill", "cloud.sleet.fill"),
    57: ("Freezing drizzle", "cloud.sleet.fill", "cloud.sleet.fill"),
    61: ("Light rain", "cloud.rain.fill", "cloud.rain.fill"),
    63: ("Rain", "cloud.rain.fill", "cloud.rain.fill"),
    65: ("Heavy rain", "cloud.heavyrain.fill", "cloud.heavyrain.fill"),
    66: ("Freezing rain", "cloud.sleet.fill", "cloud.sleet.fill"),
    67: ("Freezing rain", "cloud.sleet.fill", "cloud.sleet.fill"),
    71: ("Light snow", "cloud.snow.fill", "cloud.snow.fill"),
    73: ("Snow", "cloud.snow.fill", "cloud.snow.fill"),
    75: ("Heavy snow", "snowflake", "snowflake"),
    77: ("Snow grains", "cloud.snow.fill", "cloud.snow.fill"),
    80: ("Showers", "cloud.sun.rain.fill", "cloud.moon.rain.fill"),
    81: ("Showers", "cloud.rain.fill", "cloud.rain.fill"),
    82: ("Heavy showers", "cloud.heavyrain.fill", "cloud.heavyrain.fill"),
    85: ("Snow showers", "cloud.snow.fill", "cloud.snow.fill"),
    86: ("Snow showers", "cloud.snow.fill", "cloud.snow.fill"),
    95: ("Thunderstorm", "cloud.bolt.fill", "cloud.bolt.fill"),
    96: ("Thunderstorm, hail", "cloud.bolt.rain.fill", "cloud.bolt.rain.fill"),
    99: ("Thunderstorm, hail", "cloud.bolt.rain.fill", "cloud.bolt.rain.fill"),
}


def describe(code, day=True):
    text, sun, moon = CODES.get(code, ("Unknown", "questionmark", "questionmark"))
    return text, sun if day else moon


async def forecast(where):
    place, units = where
    params = {
        "latitude": place["lat"],
        "longitude": place["lon"],
        "current": "temperature_2m,apparent_temperature,relative_humidity_2m,weather_code,wind_speed_10m,is_day",
        "hourly": "temperature_2m,precipitation_probability,weather_code,is_day",
        "daily": "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max",
        "timezone": "auto",
        "forecast_days": 7,
        "temperature_unit": "fahrenheit" if units == "°F" else "celsius",
        "wind_speed_unit": "mph" if units == "°F" else "kmh",
    }
    async with httpx.AsyncClient(timeout=20) as client:
        r = await client.get(FORECAST, params=params)
        r.raise_for_status()
        return r.json()


async def search(name):
    async with httpx.AsyncClient(timeout=20) as client:
        r = await client.get(GEOCODING, params={"name": name, "count": 6})
        r.raise_for_status()
        return [
            {"name": p["name"], "lat": p["latitude"], "lon": p["longitude"],
             "where": ", ".join(x for x in (p.get("admin1"), p.get("country")) if x)}
            for p in r.json().get("results", [])
        ]


def next_hours(data, hours=24):
    """The hourly forecast from the current hour on."""
    h = data["hourly"]
    now = data["current"]["time"][:13]  # "2026-10-18T14"
    start = next((i for i, t in enumerate(h["time"]) if t[:13] >= now), 0)
    return [
        {"time": dt.datetime.fromisoformat(h["time"][i]), "temp": h["temperature_2m"][i],
         "rain": h["precipitation_probability"][i] or 0}
        for i in range(start, min(start + hours, len(h["time"])))
    ]


def chart(hours):
    """Temperature as a line, the chance of rain as blue bars."""
    W, H, TOP, BOTTOM, SIDE = 340, 150, 24, 20, 12

    def draw(p):
        p.clear()
        if not hours:
            return
        temps = [h["temp"] for h in hours]
        lo, hi = min(temps) - 1, max(temps) + 1
        step = (W - 2 * SIDE) / len(hours)

        def x(i):
            return SIDE + i * step + step / 2

        def y(t):
            return TOP + (hi - t) / (hi - lo) * (H - TOP - BOTTOM)

        for i, h in enumerate(hours):
            if h["rain"]:
                bar = h["rain"] / 100 * (H - TOP - BOTTOM)
                p.fill_style = "rgba(10, 132, 255, 0.35)"
                p.fill_rect(x(i) - step / 2 + 1, H - BOTTOM - bar, step - 2, bar)
        p.begin_path()
        for i, t in enumerate(temps):
            (p.move_to if i == 0 else p.line_to)(x(i), y(t))
        p.stroke_style = "#ff9f0a"
        p.line_width = 3
        p.line_join = "round"
        p.stroke()
        for i, h in enumerate(hours):
            if i % 3 == 0:
                p.circle(x(i), y(h["temp"]), 3, fill="#ff9f0a")
                p.text(f"{h['temp']:.0f}°", x(i), y(h["temp"]) - 8, color="#ff9f0a", font="bold 11px system-ui",
                       align="center")
                p.text("Now" if i == 0 else f"{h['time']:%H}", x(i), H - 4, color="#8e8e93",
                       font="11px system-ui", align="center")

    return ui.Canvas(draw, width=W, height=H)


def Weather():
    place = ui.signal()  # {"name", "lat", "lon"}
    units = ui.signal("°C")
    query = ui.signal("")
    weather = ui.resource(forecast, lambda: place() and (place(), units()))

    def here():
        location.start_updates()
        spot = location.get_location()
        location.stop_updates()
        if not spot:
            ui.toast("No location: allow it in Settings")
            place.set(place.peek() or FALLBACK)
            return
        address = (location.reverse_geocode(spot) or [{}])[0]
        place.set({"name": address.get("City") or address.get("Name") or "Here", "lat": spot["latitude"],
                   "lon": spot["longitude"]})

    async def find(text):
        if not text.strip():
            return
        try:
            places = await search(text.strip())
        except httpx.HTTPError as e:
            await ui.alert("Search failed", str(e))
            return
        if not places:
            ui.toast(f"Nothing found for “{text}”")
            return
        if len(places) > 1:
            labels = [f"{p['name']}, {p['where']}" for p in places]
            chosen = await ui.choose("Which one?", labels)
            if chosen is None:
                return
            places = [places[labels.index(chosen)]]
        place.set(places[0])
        query.set("")

    def now_card(data):
        c = data["current"]
        text, icon = describe(c["weather_code"], c["is_day"])
        u = data["current_units"]
        return ui.Card(
            ui.HStack(
                ui.VStack(
                    ui.Text(f"{c['temperature_2m']:.0f}°", font_size=64, font_weight="thin"),
                    ui.Text(text, font="title3"),
                    spacing=0,
                    align="leading",
                ),
                ui.Spacer(),
                ui.Icon(icon, size=64, color="orange" if c["is_day"] and "sun" in icon else "secondary"),
            ),
            ui.Text(f"Feels like {c['apparent_temperature']:.0f}° · humidity {c['relative_humidity_2m']}% · "
                    f"wind {c['wind_speed_10m']:.0f} {u['wind_speed_10m']}", font="subheadline", color="secondary"),
        )

    def day_row(data, i):
        d = data["daily"]
        day = dt.date.fromisoformat(d["time"][i])
        text, icon = describe(d["weather_code"][i])
        rain = d["precipitation_probability_max"][i]
        return ui.Row(
            "Today" if i == 0 else f"{day:%A}",
            subtitle=text + (f" · {rain}% rain" if rain else ""),
            icon=icon,
            detail=f"{d['temperature_2m_min'][i]:.0f}° / {d['temperature_2m_max'][i]:.0f}°",
        )

    def body():
        if weather.error():
            return ui.Card(ui.Label("Couldn't load the weather", icon="exclamationmark.triangle"),
                           ui.Text(str(weather.error()), font="footnote", color="secondary"),
                           ui.Button("Try again", on_click=weather.refetch, kind="tinted"))
        data = weather()
        if data is None:
            return ui.HStack(ui.Spacer(), ui.ProgressView(), ui.Spacer(), padding=40)
        return ui.VStack(
            now_card(data),
            ui.Section(chart(next_hours(data)), header="Next 24 hours",
                       footer="Bars: the chance of rain."),
            ui.Section(*[day_row(data, i) for i in range(len(data["daily"]["time"]))], header="This week"),
            spacing=16,
        )

    ui.on_mount(here)
    return ui.Screen(
        lambda: place()["name"] if place() else "Weather",
        ui.TextField(query, placeholder="Search for a city", kind="search", on_submit=find),
        ui.Picker(["°C", "°F"], units),
        lambda: body(),
        trailing=ui.Button(icon="location", kind="plain", on_click=here, accessibility_label="My location"),
    )


ui.run(Weather)
