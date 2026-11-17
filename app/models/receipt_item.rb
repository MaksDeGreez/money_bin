# One line printed on a receipt: a product, how many, the unit price, and what was paid for it.
#
# `amount` is what was paid for the item after its discount, in the receipt currency, as a positive number
# for a purchase. It may be negative (a bottle deposit returned) or zero (a free item). `discount` is the
# reduction already taken off, never negative. Money has at most two decimal places and `quantity` at most
# three; a value with more is refused, never rounded. The model does not check quantity x unit_price - discount
# against amount: OCR output and shop rounding are not that tidy, and `amount` is the figure that counts.
#
# `suggested_category` is the categoriser's best guess, with its `confidence` (0..1). `category` is the
# accepted one; only it is used when the receipt is accepted into the ledger. `accepted_by_user` records
# that a person confirmed the category. Both categories must be categories, not groups.
#
# `position` is the item's place on the receipt, unique inside the receipt.
class ReceiptItem < ApplicationRecord
  # quantity is decimal(12, 3): grams of a kilogram, millilitres of a litre.
  QUANTITY_DECIMAL_PLACES = 3

  belongs_to :receipt, inverse_of: :items
  belongs_to :category, optional: true
  belongs_to :suggested_category, class_name: "Category", optional: true

  normalizes :name, with: ->(value) { value.squish }

  validates :position, numericality: { only_integer: true, greater_than_or_equal_to: 0 },
    uniqueness: { scope: :receipt_id }
  validates :name, presence: true
  validates :amount, presence: true,
    numericality: { greater_than: -Transaction::AMOUNT_LIMIT, less_than: Transaction::AMOUNT_LIMIT }
  validates :discount, numericality: { greater_than_or_equal_to: 0, less_than: Transaction::AMOUNT_LIMIT }
  validates :quantity, numericality: { greater_than: 0, less_than: 10**9 }, allow_nil: true
  validates :unit_price, numericality: { greater_than: -Transaction::AMOUNT_LIMIT, less_than: Transaction::AMOUNT_LIMIT },
    allow_nil: true
  validates :amount, :unit_price, :discount, decimal_places: { maximum: Transaction::MONEY_DECIMAL_PLACES }
  validates :quantity, decimal_places: { maximum: QUANTITY_DECIMAL_PLACES }
  validates :confidence, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 }, allow_nil: true
  validates :accepted_by_user, inclusion: { in: [ true, false ] }
  validate { category_is_a_leaf(:category) if category_id.present? && will_save_change_to_category_id? }
  validate do
    category_is_a_leaf(:suggested_category) if suggested_category_id.present? && will_save_change_to_suggested_category_id?
  end

  private
    def category_is_a_leaf(name)
      category = public_send(name)
      if category.nil?
        errors.add(name, "does not exist")
      elsif category.group?
        errors.add(name, "must be a category, not a group")
      end
    end
end
