# What money was spent on (or came from). The tree has two levels:
#
# - a group is a root ("Eating out"): it has no parent and only collects categories;
# - a category is a child of a group ("Eating out / Takeaway & fast food"): transaction lines and receipt
#   items point at categories, never at groups.
#
# A category cannot be placed under another category, and a group that has categories cannot get a parent.
#
# `slug` is the stable, globally unique key that the ML service and the API use. A group's slug is its
# parameterized name ("eating-out"); a category's slug is "<group slug>/<own part>"
# ("eating-out/takeaway-fast-food"). It is built from the name when blank and never changes on its own:
# renaming a category keeps its slug. Moving a category to another group needs a new slug (set it to
# blank to rebuild it).
#
# `position` orders categories inside their level (groups among groups, categories inside their group).
# `description` says in one sentence what belongs there; it helps both people and the categoriser.
class Category < ApplicationRecord
  UNCATEGORISED_SLUG = "uncategorised/uncategorised".freeze
  SLUG_PART = /[a-z0-9]+(?:-[a-z0-9]+)*/
  SLUG_FORMAT = %r{\A#{SLUG_PART}(?:/#{SLUG_PART})?\z}

  belongs_to :parent, class_name: "Category", optional: true, inverse_of: :children
  has_many :children, -> { order(:position, :name) }, class_name: "Category", foreign_key: :parent_id, inverse_of: :parent,
    dependent: :restrict_with_error
  has_many :transaction_lines, dependent: :restrict_with_error
  has_many :receipt_items, dependent: :restrict_with_error
  # Suggestions are only guesses; they go when the category goes.
  has_many :suggested_receipt_items, class_name: "ReceiptItem", foreign_key: :suggested_category_id, inverse_of: :suggested_category,
    dependent: :nullify

  scope :groups, -> { where(parent_id: nil) }
  scope :leaves, -> { where.not(parent_id: nil) }
  scope :ordered, -> { order(:position, :name) }

  normalizes :name, with: ->(value) { value.squish }

  before_validation :build_slug, if: -> { slug.blank? && name.present? }
  before_validation :default_position, if: -> { position.nil? }

  validates :name, presence: true, uniqueness: { scope: :parent_id }
  validates :slug, presence: true, uniqueness: true, format: { with: SLUG_FORMAT, allow_blank: true }
  validates :position, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate :parent_exists, if: -> { parent_id.present? && will_save_change_to_parent_id? }
  validate :parent_is_a_group
  validate :slug_matches_level

  # The category for lines nobody has categorised yet. It comes from the taxonomy seed; raises
  # ActiveRecord::RecordNotFound when the seed has not run.
  def self.uncategorised
    find_by!(slug: UNCATEGORISED_SLUG)
  end

  def self.slug_part(name)
    name.to_s.parameterize
  end

  def group?
    parent_id.nil?
  end

  def leaf?
    !group?
  end

  # "Eating out / Takeaway & fast food" for a category, the plain name for a group.
  def full_name
    parent ? "#{parent.name} / #{name}" : name
  end

  private
    def build_slug
      part = self.class.slug_part(name)
      return if part.blank?

      self.slug = parent ? "#{parent.slug}/#{part}" : part
    end

    def default_position
      self.position = (Category.where(parent_id:).maximum(:position) || 0) + 1
    end

    # The parent is optional, so belongs_to does not check it; a made-up id would otherwise surface as
    # ActiveRecord::InvalidForeignKey.
    def parent_exists
      errors.add(:parent, "does not exist") if parent.nil?
    end

    def parent_is_a_group
      return unless parent

      if parent == self || (persisted? && parent_id == id)
        errors.add(:parent, "cannot be the category itself")
      elsif !parent.group?
        errors.add(:parent, "must be a group (a category without a parent)")
      elsif persisted? && children.exists?
        errors.add(:parent, "cannot be set on a group that has categories")
      end
    end

    def slug_matches_level
      return if slug.blank? || errors.include?(:slug)

      if parent.nil?
        errors.add(:slug, "of a group must not contain a slash") if slug.include?("/")
      elsif !slug.start_with?("#{parent.slug}/")
        errors.add(:slug, "must start with the group slug (#{parent.slug}/)")
      end
    end
end
