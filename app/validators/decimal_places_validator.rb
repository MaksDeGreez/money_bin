# Refuses a number with more decimal places than its column keeps, instead of letting it be rounded.
#
#   validates :amount, decimal_places: { maximum: 2 }
#
# Rails rounds a decimal to the column's scale when it is assigned, so "12.345" would be stored as 12.35
# without any error. This validator looks at the value as it was given (before the type cast):
# - Integer, BigDecimal and Rational are checked exactly (Rational(10, 3) never fits);
# - a String is read as a decimal; text that is not a number is left to the numericality validation;
# - a Float is checked through its shortest written form (0.105 has three places), which is what the
#   caller wrote. Callers should still prefer BigDecimal or decimal strings for money.
# nil and blank values pass; presence is a separate rule.
class DecimalPlacesValidator < ActiveModel::EachValidator
  def check_validity!
    maximum = options[:maximum]
    raise ArgumentError, ":maximum must be a non-negative Integer" unless maximum.is_a?(Integer) && maximum >= 0
  end

  # The exact value of `value` as a Rational, or nil when it is not a finite number.
  def self.exact(value)
    case value
    when Integer, Rational then value.to_r
    when BigDecimal then value.finite? ? value.to_r : nil
    when Float then value.finite? ? BigDecimal(value.to_s).to_r : nil
    when String then BigDecimal(value.strip, exception: false)&.then { |number| number.finite? ? number.to_r : nil }
    end
  end

  # True when `value` is a finite number with at most `maximum` decimal places.
  def self.fits?(value, maximum)
    number = exact(value)
    !number.nil? && (number * 10**maximum).denominator == 1
  end

  def validate_each(record, attribute, value)
    raw = record.respond_to?(:read_attribute_before_type_cast) ? record.read_attribute_before_type_cast(attribute) : value
    return if raw.nil? || exact(raw).nil?
    return if self.class.fits?(raw, options[:maximum])

    record.errors.add(attribute, :too_many_decimal_places, count: options[:maximum],
      message: options[:message] || "must have at most #{options[:maximum]} decimal places (it is never rounded)")
  end

  private
    def exact(value)
      self.class.exact(value)
    end
end
