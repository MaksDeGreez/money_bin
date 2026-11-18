# Reads an amount or a quantity as a person types it into a form, before the model sees it.
#
#   MoneyInput.normalize("1 250,40")  # => "1250.40"
#   MoneyInput.normalize(" ")         # => ""
#   MoneyInput.normalize("12,5.0")    # => nil (not a decimal number)
#
# - Spaces of any kind (a thin space or a no-break space between thousands) are dropped.
# - A comma is the decimal separator when it is the only separator ("12,50"); with both a comma and a dot
#   the text is ambiguous and refused.
# - A typographic minus (U+2212) is a minus; a leading plus is dropped.
# - Only plain decimals pass: no exponent ("1e3"), no thousands separators, no currency sign.
#
# The result is a String, so the model still sees the value exactly as given: DecimalPlacesValidator then
# refuses more places than the column keeps, and nothing is ever rounded or read through a Float. The
# browser's live totals (money_totals_controller.js) read input with the same rules.
module MoneyInput
  SPACES = /[[:space:]  ]/
  DECIMAL = /\A-?(?:\d+(?:\.\d+)?|\.\d+)\z/
  MESSAGE = "must be a number such as 12.50 or 12,50".freeze

  module_function

  # The plain decimal text, "" for a blank value, or nil when the text is not a decimal number.
  # Anything that is not a String is returned as it is.
  def normalize(text)
    return text unless text.is_a?(String)

    value = text.gsub(SPACES, "").tr("−", "-").delete_prefix("+")
    return "" if value.empty?

    value = value.tr(",", ".") if value.count(",") == 1 && !value.include?(".")
    value if value.match?(DECIMAL)
  end
end
