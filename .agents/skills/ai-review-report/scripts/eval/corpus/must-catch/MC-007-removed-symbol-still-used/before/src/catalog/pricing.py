"""Catalog pricing helpers."""

from decimal import Decimal

TAX_RATE = Decimal("0.25")


def price_with_tax(net: Decimal) -> Decimal:
    return (net * (1 + TAX_RATE)).quantize(Decimal("0.01"))


def normalize_sku(sku: str) -> str:
    """Upper-case and strip a SKU so lookups match the catalog keys."""
    return sku.strip().upper()
