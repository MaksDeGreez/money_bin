# Whether receipt items get category suggestions at all (docs/domain.md, "Labelling without suggestions").
#
#   ItemSuggestions.enabled?  # => false with CATEGORISE_BACKEND=off
#
# The same setting the ML service reads (`CATEGORISE_BACKEND`, in the shared .env): `off` switches every
# suggestion off, the label memory's included, so the owner can label receipts that no categoriser pre-filled.
# Then nothing fills suggestions (Receipts::SuggestCategories does nothing and records nothing), and the
# review form shows no suggestion and no suggestion control. Any other value, or none, means on.
module ItemSuggestions
  SETTING = "CATEGORISE_BACKEND".freeze
  OFF = "off".freeze

  module_function

  def enabled?
    ENV.fetch(SETTING, "").strip.downcase != OFF
  end
end
