# Types: Terrarium checks your code while you type, with ruff (common bugs
# and style) and ty (types). Every wavy underline in this file is a real
# mistake, numbered in the comments.
#
# - Put the cursor on an underline: the bar above the keyboard says what
#   is wrong, with a quick fix when there is one.
# - The badge in the corner counts the problems left. Fix them all!
#
# Python itself doesn't check type hints, so the program runs anyway, but
# each mistake is a bug waiting to happen. Run it to watch two of them bite.
import json  # 1. never used (ruff; the quick fix removes it)
from dataclasses import dataclass


@dataclass
class Book:
    title: str
    year: int
    rating: float | None = None  # None: not rated yet


def average_rating(books: list[Book]) -> int:  # 2. it returns a float, not an int (ty)
    ratings = [b.rating for b in books if b.rating is not None]
    return sum(ratings) / len(ratings)


def stars(book: Book) -> str:
    return "★" * round(book.rating)  # 3. rating can be None, and round(None) fails (ty)


def tag(book: Book, label: str, tags: list[str] = []) -> list[str]:  # 4. one list, shared by every call (ruff)
    tags.append(f"{label}: {book.title}")
    return tags


books = [
    Book("Dune", 1965, 4.6),
    Book("Neuromancer", 1984, 4.1),
    Book("The Left Hand of Darkness", "1969"),  # 5. a str where an int belongs (ty)
]

print(f"Average rating: {average_rating(books):.2f}")
print(stars(books[0]), books[0].title)
print(tag(books[0], "classic"))
print(tag(books[1], "cyberpunk"))  # surprise: Dune's tag is still in there (4.)
for book in sorted(books, key=lambda b: b.year):  # TypeError: can't compare "1969" with 1984 (5.)
    print(book.year, book.title)
