# Labelling: a person saves a corrected receipt as ground truth (docs/domain.md, "Manual ground truth").
#
# Receipts:
# - `ocr_prompt_version`: the prompt version of the OCR answer that filled the receipt, copied from the answer
#   like `ocr_model_name` and `ocr_model_version`. `ocr_raw` keeps it too, but "Enter by hand" replaces
#   `ocr_raw` while the items of an earlier read stay, so the model that pre-filled them must be on columns
#   that stay. Filled here from `ocr_raw` for receipts read before.
# - `filled_from`: `dps_xml` when a person filled the receipt's fields and items from its tax-service record
#   in the review form (nil otherwise); a new OCR result clears it. It says what pre-filled the form when the
#   receipt is saved as ground truth.
# - `categoriser_model_name`: the categoriser whose suggestions the items (and a slip) carry. Whatever fills
#   the suggestions sets it (nothing does yet); a new OCR result, which replaces the items, clears it.
#
# Ground truth:
# - `categories_known`: whether the document gives a category for every item (and for a card slip, the
#   slip's); false means every category in it is null. Schema version 2 brings categories, so a version 1
#   record never has them.
# - `prefilled_model_version`, `prefilled_prompt_version`: the version and prompt version of the model named
#   by `prefilled_by`, for a manual record pre-filled by a model.
# - `categories_prefilled_by`: the categoriser whose suggestions were on the form when a person chose the
#   categories of a manual record (nil when there were none).
# - A manual record must say what pre-filled it; an imported one has no categories and no pre-fill.
class AddLabellingFields < ActiveRecord::Migration[8.1]
  def up
    change_table :receipts, bulk: true do |t|
      t.string :ocr_prompt_version
      t.string :filled_from
      t.string :categoriser_model_name
      t.check_constraint "filled_from IS NULL OR filled_from = 'dps_xml'", name: "receipts_filled_from_allowed"
    end
    execute <<~SQL
      UPDATE receipts SET ocr_prompt_version = ocr_raw->>'prompt_version'
      WHERE jsonb_typeof(ocr_raw) = 'object' AND jsonb_typeof(ocr_raw->'prompt_version') = 'string'
    SQL

    change_table :receipt_ground_truths, bulk: true do |t|
      t.boolean :categories_known, null: false, default: false
      t.string :prefilled_model_version
      t.string :prefilled_prompt_version
      t.string :categories_prefilled_by
    end
    remove_check_constraint :receipt_ground_truths, name: "receipt_ground_truths_imported_fields"
    remove_check_constraint :receipt_ground_truths, name: "receipt_ground_truths_manual_fields"
    add_check_constraint :receipt_ground_truths,
      "source <> 'dps_xml' OR (source_sha256 IS NOT NULL AND source_format IS NOT NULL AND prefilled_by IS NULL " \
      "AND prefilled_model_version IS NULL AND prefilled_prompt_version IS NULL AND categories_prefilled_by IS NULL " \
      "AND NOT categories_known)",
      name: "receipt_ground_truths_imported_fields"
    add_check_constraint :receipt_ground_truths,
      "source <> 'manual' OR (source_sha256 IS NULL AND source_format IS NULL AND prefilled_by IS NOT NULL)",
      name: "receipt_ground_truths_manual_fields"
    add_check_constraint :receipt_ground_truths, "schema_version >= 2 OR NOT categories_known",
      name: "receipt_ground_truths_categories_need_version_2"
    # Categories not known: no category anywhere in the document.
    add_check_constraint :receipt_ground_truths,
      "categories_known OR (NOT jsonb_path_exists(document, '$.items[*].category_slug ? (@ != null)') " \
      "AND NOT jsonb_path_exists(document, '$.category_slug ? (@ != null)'))",
      name: "receipt_ground_truths_unknown_categories_null"
  end

  def down
    remove_check_constraint :receipt_ground_truths, name: "receipt_ground_truths_unknown_categories_null"
    remove_check_constraint :receipt_ground_truths, name: "receipt_ground_truths_categories_need_version_2"
    remove_check_constraint :receipt_ground_truths, name: "receipt_ground_truths_manual_fields"
    remove_check_constraint :receipt_ground_truths, name: "receipt_ground_truths_imported_fields"
    add_check_constraint :receipt_ground_truths,
      "source <> 'dps_xml' OR (source_sha256 IS NOT NULL AND source_format IS NOT NULL AND prefilled_by IS NULL)",
      name: "receipt_ground_truths_imported_fields"
    add_check_constraint :receipt_ground_truths, "source <> 'manual' OR (source_sha256 IS NULL AND source_format IS NULL)",
      name: "receipt_ground_truths_manual_fields"
    change_table :receipt_ground_truths, bulk: true do |t|
      t.remove :categories_known, :prefilled_model_version, :prefilled_prompt_version, :categories_prefilled_by
    end
    remove_check_constraint :receipts, name: "receipts_filled_from_allowed"
    change_table :receipts, bulk: true do |t|
      t.remove :ocr_prompt_version, :filled_from, :categoriser_model_name
    end
  end
end
