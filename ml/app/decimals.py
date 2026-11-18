"""Exact sums of decimal values (costs), whatever their number of digits."""

from collections.abc import Iterable
from decimal import Decimal, localcontext

# A value has at most `MAX_DIGITS` digits and an exponent within +-`MAX_DIGITS`,
# so it lies between 10^-50 and 10^100: 150 digit positions. With 20 more for
# the carries of up to 10^20 values, the sum is exact, never rounded.
MAX_DIGITS = 50
_SUM_PRECISION = 3 * MAX_DIGITS + 20


def bounded(value: Decimal) -> Decimal | None:
    """`value` when it is finite with at most `MAX_DIGITS` digits, else None."""
    if not value.is_finite() or len(value.as_tuple().digits) > MAX_DIGITS:
        return None
    exponent = value.as_tuple().exponent
    assert isinstance(exponent, int)
    if abs(exponent) > MAX_DIGITS:
        return None
    return value


def exact_sum(values: Iterable[Decimal]) -> Decimal:
    """The sum of `values`, computed with enough precision to be exact."""
    with localcontext() as context:
        context.prec = _SUM_PRECISION
        return sum(values, Decimal("0"))
