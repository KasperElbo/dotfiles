from dotfiles_smoke import multiply


def test_multiply() -> None:
    assert multiply(6, 7) == 42
