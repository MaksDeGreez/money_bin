"""Exact sums of decimal values (costs), whatever their number of digits."""

from collections.abc import Iterable
from decimal import Decimal, localcontext

# The most digits, and the largest exponent either way, of one reported cost.
# Anything beyond is not a price but a malformed answer.
MAX_DIGITS = 50


def bounded(value: Decimal) -> Decimal | None:
    """`value` when it is finite with at most `MAX_DIGITS` digits and a modest exponent."""
    if not value.is_finite():
        return None
    _sign, digits, exponent = value.as_tuple()
    assert isinstance(exponent, int)
    if len(digits) > MAX_DIGITS or abs(exponent) > MAX_DIGITS:
        return None
    return value


def exact_sum(values: Iterable[Decimal]) -> Decimal:
    """The exact sum of finite `values`: the precision is taken from the values themselves."""
    terms = [value for value in values if not value.is_zero()]
    if not terms:
        return Decimal("0")
    highest = max(value.adjusted() for value in terms)
    lowest = min(int(value.as_tuple().exponent) for value in terms)
    with localcontext() as context:
        # Every digit position the terms span, plus room for the carries.
        context.prec = highest - lowest + 1 + len(str(len(terms))) + 1
        context.Emax = max(context.Emax, highest + len(str(len(terms))) + 1)
        context.Emin = min(context.Emin, lowest)
        return sum(terms, Decimal("0"))
