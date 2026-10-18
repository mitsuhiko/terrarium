"""The world of the adventure: rooms, items and what you can do with them.

All of it comes from rooms.json, so a new room or puzzle needs no code.
Adventure.py imports this module: `from world import Game`.
"""

import json
from dataclasses import dataclass, field
from pathlib import Path

WORLD = Path(__file__).with_name("rooms.json")
DIRECTIONS = {"n": "north", "s": "south", "e": "east", "w": "west", "u": "up", "d": "down"}


@dataclass
class Room:
    name: str
    description: str
    exits: dict[str, str]
    items: list[str]
    locked: dict[str, dict] = field(default_factory=dict)


@dataclass
class Item:
    name: str
    words: list[str]
    description: str


class Game:
    def __init__(self, path=WORLD):
        data = json.loads(Path(path).read_text())
        self.title = data["title"]
        self.intro = data["intro"]
        self.rooms = {key: Room(**room) for key, room in data["rooms"].items()}
        self.items = {key: Item(**item) for key, item in data["items"].items()}
        self.actions = data["actions"]
        self.here = data["start"]
        self.inventory: list[str] = []
        self.used: set[int] = set()  # actions that only work once
        self.moves = 0
        self.won = False

    @property
    def room(self):
        return self.rooms[self.here]

    def find(self, word, where):
        """The item in `where` (a list of item keys) that `word` names."""
        for key in where:
            if word in self.items[key].words:
                return key
        return None

    # -- commands: each returns what to print --------------------------------------

    def look(self):
        lines = [self.room.name.upper(), self.room.description]
        if self.room.items:
            lines.append("You see " + ", ".join(self.items[k].name for k in self.room.items) + ".")
        lines.append("Exits: " + ", ".join(self.room.exits) + ".")
        return "\n".join(lines)

    def go(self, direction):
        direction = DIRECTIONS.get(direction, direction)
        if direction not in self.room.exits:
            return "You can't go that way."
        lock = self.room.locked.get(direction)
        if lock and lock["needs"] not in self.inventory:
            return lock["message"]
        self.here = self.room.exits[direction]
        self.moves += 1
        return self.look()

    def take(self, word):
        key = self.find(word, self.room.items)
        if key is None:
            return f"There is no {word} here."
        self.room.items.remove(key)
        self.inventory.append(key)
        return f"You take {self.items[key].name}."

    def drop(self, word):
        key = self.find(word, self.inventory)
        if key is None:
            return f"You don't have a {word}."
        self.inventory.remove(key)
        self.room.items.append(key)
        return f"You drop {self.items[key].name}."

    def examine(self, word):
        key = self.find(word, self.inventory + self.room.items)
        return self.items[key].description if key else f"You don't see a {word}."

    def show_inventory(self):
        if not self.inventory:
            return "You carry nothing."
        return "You carry " + ", ".join(self.items[k].name for k in self.inventory) + "."

    def use(self, word):
        key = self.find(word, self.inventory)
        if key is None:
            return f"You don't have a {word}."
        for i, action in enumerate(self.actions):
            if action["item"] != key or action.get("room", self.here) != self.here or i in self.used:
                continue
            if action.get("once"):
                self.used.add(i)
            if "gives" in action:
                self.inventory.append(action["gives"])
            if "replace" in action:
                self.inventory[self.inventory.index(key)] = action["replace"]
            if action.get("consume"):
                self.inventory.remove(key)
            if action.get("win"):
                self.won = True
            self.moves += 1
            return action["message"]
        return f"Nothing happens when you use {self.items[key].name} here."
