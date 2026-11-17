"""Checkout totals."""

from decimal import Decimal

from catalog.pricing import normalize_sku, price_with_tax

CATALOG = {"ABC-1": Decimal("10.00"), "XYZ-9": Decimal("4.50")}


def checkout_total(skus: list[str]) -> Decimal:
    total = Decimal("0")
    for sku in skus:
        total += price_with_tax(CATALOG[normalize_sku(sku)])
    return total
