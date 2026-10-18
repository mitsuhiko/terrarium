# Navigation: a list that pushes detail screens, a sheet to add, and dialogs.
import ui

people = ui.store([
    {"name": "Ada Lovelace", "role": "Mathematician", "fav": True},
    {"name": "Grace Hopper", "role": "Admiral", "fav": False},
    {"name": "Guido van Rossum", "role": "BDFL emeritus", "fav": False},
])


def Detail(person):
    nav = ui.navigation()

    async def remove():
        if await ui.confirm(f"Delete {person.name}?", destructive=True, ok="Delete"):
            people.remove(person)
            nav.pop()
            ui.toast("Deleted")

    async def rename():
        name = await ui.prompt("Rename", value=person.name)
        if name:
            person.name = name

    return ui.Screen(
        lambda: person.name,
        ui.Section(
            ui.Row("Role", detail=lambda: person.role),
            ui.Toggle("Favorite", ui.bind(person, "fav")),
        ),
        ui.Section(
            ui.Button("Rename…", on_click=rename),
            ui.Button("Delete", on_click=remove, kind="destructive"),
        ),
        trailing=ui.Button(icon="star.fill", on_click=lambda: person.update(fav=not person.fav),
                           color=lambda: "#ff9f0a" if person.fav else None),
    )


def AddSheet(open_):
    name = ui.signal("")
    role = ui.signal("")

    def save():
        people.append({"name": name(), "role": role() or "Unknown", "fav": False})
        name.set("")
        role.set("")
        open_.set(False)

    return ui.Sheet(
        ui.Section(ui.TextField(name, placeholder="Name"), ui.TextField(role, placeholder="Role")),
        ui.Button("Save", on_click=save, disabled=lambda: not name().strip()),
        open=open_, title="New Person", size="medium",
    )


def People():
    adding = ui.signal(False)
    favorites = ui.computed(lambda: [p.name for p in people if p.fav])
    return ui.Screen(
        "People",
        ui.Section(
            ui.For(people, lambda p: ui.Row(
                lambda: p.name,
                subtitle=lambda: p.role,
                icon=lambda: "star.fill" if p.fav else "person",
                accessory="chevron",
                on_click=lambda: ui.navigation().push(Detail, p),
            )),
            footer=lambda: f"Favorites: {', '.join(favorites()) or 'none'}",
        ),
        AddSheet(adding),
        trailing=ui.Button(icon="plus", on_click=lambda: adding.set(True), aria_label="Add"),
    )


ui.run(ui.NavigationStack(People))
