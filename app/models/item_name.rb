# The normalised form of a receipt item's name, under which the label memory matches names
# (docs/domain.md, "Label memory").
#
#   ItemName.key("МОЛ 2,5% 900Г")  # => "мол25900г"
#
# Unicode NFKC, lower case, the Latin letters that look like Cyrillic ones in print (a, b, c, e, h, i, k, m, o,
# p, t, x, y: a receipt printer or OCR mixes them) turned into those Cyrillic letters, then everything that is
# not a letter or a digit dropped: spaces, punctuation, apostrophes, signs. Sizes stay (900г, 0,5л): they are
# welded to the name in irregular forms ("Вод1.5літ", "Сан750"), and the same product from the same shop
# prints the same way, which is what the memory is for. A missed match costs a model call; a wrong merge
# would put one product's label on another.
#
# Changing the rule needs a migration that recomputes `receipt_items.name_key` (the first one called this
# method), or older labels stop matching.
#
# ml/evaluation/label_memory.py is the same rule for the offline evaluation; both read the shared cases in
# ml/tests/fixtures/item_name_keys.json, so the two cannot drift apart.
module ItemName
  LATIN_LOOKALIKES = "abcehikmoptxy".freeze
  CYRILLIC_LETTERS = "авсенікмортху".freeze
  NOT_A_LETTER_OR_DIGIT = /[^\p{L}\p{N}]/

  module_function

  def key(name)
    name.to_s.unicode_normalize(:nfkc).downcase.tr(LATIN_LOOKALIKES, CYRILLIC_LETTERS).gsub(NOT_A_LETTER_OR_DIGIT, "")
  end
end
