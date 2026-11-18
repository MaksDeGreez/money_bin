# How values are written in the API's JSON (docs/openapi.yaml):
# - money as a decimal string with exactly two places ("-1250.40"), quantities with exactly three
#   ("0.850"), never a JSON number: a float cannot hold every decimal amount;
# - dates as ISO 8601 ("2026-10-03"), times as ISO 8601 with the Kyiv offset ("2026-10-03T18:40:00+03:00").
#
# Nothing is rounded: a value with more places than the format has raises ArgumentError, since it would
# mean a bug upstream (the columns hold two and three places).
module JsonFormat
  MONEY_PLACES = 2
  QUANTITY_PLACES = 3

  module_function

  def money(value)
    decimal(value, MONEY_PLACES)
  end

  def quantity(value)
    decimal(value, QUANTITY_PLACES)
  end

  def decimal(value, places)
    return nil if value.nil?
    raise ArgumentError, "expected a BigDecimal or an Integer, got #{value.class}" unless value.is_a?(BigDecimal) || value.is_a?(Integer)

    exact = BigDecimal(value)
    raise ArgumentError, "#{exact.to_s('F')} has more than #{places} decimal places" unless exact.round(places) == exact

    whole, fraction = exact.abs.to_s("F").split(".")
    "#{'-' if exact.negative?}#{whole}.#{fraction.to_s.ljust(places, '0')}"
  end

  def date(value)
    value&.iso8601
  end

  # In the app time zone (Kyiv), so the offset is +02:00 or +03:00.
  def time(value)
    value&.in_time_zone&.iso8601
  end
end
