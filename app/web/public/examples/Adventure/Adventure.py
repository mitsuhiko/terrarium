# A text adventure in three files:
#
#   Adventure.py  this one: reads what you type and answers
#   world.py      the rules: rooms, items, what each command does
#   rooms.json    the map and the puzzles, as data
#
# `from world import Game` imports world.py from this folder, like on a
# computer. README.md explains how to add rooms. Type "help" to start.
import textwrap

from world import Game

HELP = """Commands:
  look                  where am I?
  go north (or n, s, e, w)
  take / drop / examine <thing>
  use <thing>           try it here
  inventory (or i)      what am I carrying?
  quit"""


def say(text):
    for paragraph in text.split("\n"):
        print(textwrap.fill(paragraph, width=60, subsequent_indent="  " if paragraph.startswith("  ") else ""))
    print()


def main():
    game = Game()
    say(f"*** {game.title} ***\n{game.intro}")
    say(game.look())
    commands = {
        "look": lambda _: game.look(),
        "l": lambda _: game.look(),
        "go": game.go,
        "take": game.take,
        "get": game.take,
        "drop": game.drop,
        "examine": game.examine,
        "x": game.examine,
        "read": game.examine,
        "use": game.use,
        "eat": game.use,
        "inventory": lambda _: game.show_inventory(),
        "i": lambda _: game.show_inventory(),
        "help": lambda _: HELP,
    }
    while not game.won:
        words = input("> ").strip().lower().split(maxsplit=1)
        if not words:
            continue
        verb, rest = words[0], words[1] if len(words) > 1 else ""
        if verb in ("quit", "q"):
            say("Bye!")
            return
        if verb in ("north", "south", "east", "west", "up", "down", "n", "s", "e", "w", "u", "d"):
            verb, rest = "go", verb
        if verb not in commands:
            say("I don't understand that. Type help for the commands.")
        elif verb in ("go", "take", "get", "drop", "examine", "x", "read", "use", "eat") and not rest:
            say("Go where?" if verb == "go" else f"{verb.capitalize()} what?")
        else:
            say(commands[verb](rest))
    say(f"You saved the moon orchid in {game.moves} moves. The end.")


main()
