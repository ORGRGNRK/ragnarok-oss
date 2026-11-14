from stats import mean, median


def test_mean():
    assert mean([1, 2, 3, 4]) == 2.5


def test_median_odd_unsorted():
    assert median([3, 1, 2]) == 2


def test_median_even_unsorted():
    assert median([4, 1, 3, 2]) == 2.5


def test_median_already_sorted():
    assert median([1, 2, 3, 4, 5]) == 3
