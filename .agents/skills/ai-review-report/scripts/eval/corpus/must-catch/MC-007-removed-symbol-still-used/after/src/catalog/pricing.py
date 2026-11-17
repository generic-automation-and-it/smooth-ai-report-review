"""Catalog pricing helpers."""

from decimal import Decimal

TAX_RATE = Decimal("0.25")


def price_with_tax(net: Decimal) -> Decimal:
    return (net * (1 + TAX_RATE)).quantize(Decimal("0.01"))
