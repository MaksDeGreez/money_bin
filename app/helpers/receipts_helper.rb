# Labels and small pieces of the receipt pages. Badges come from UiHelper; the tone maps hold symbols
# of UiHelper::BADGE_TONES, never class names.
module ReceiptsHelper
  STATUS_LABELS = {
    "uploaded" => "Not read yet", "processing" => "Reading", "extracted" => "Read, to review",
    "reviewed" => "Accepted", "failed" => "OCR failed"
  }.freeze
  STATUS_TONES = {
    "uploaded" => :neutral, "processing" => :signal, "extracted" => :accent, "reviewed" => :solid, "failed" => :danger
  }.freeze
  KIND_LABELS = { "fiscal" => "Fiscal receipt", "card_slip" => "Card slip" }.freeze
  QR_FIELD_LABELS = {
    issued_at: "Issued at", total: "Total", fiscal_number: "Fiscal number", receipt_number: "Receipt number"
  }.freeze

  # The receipt's name in lists and titles: its ingest number, or its id for one uploaded in the app.
  def receipt_label(receipt)
    receipt.ingest_id || "Receipt ##{receipt.id}"
  end

  # OCR is queued or running for the receipt: a page showing it waits for a live update.
  def receipt_ocr_in_flight?(receipt)
    receipt.ocr_in_flight?
  end

  def receipt_status_label(status)
    STATUS_LABELS.fetch(status.to_s)
  end

  def receipt_status_badge(receipt)
    ui_badge receipt_status_label(receipt.status), tone: STATUS_TONES.fetch(receipt.status)
  end

  def receipt_kind_label(receipt)
    KIND_LABELS.fetch(receipt.kind, "Not known yet")
  end

  # Money as stored, two decimals, thin groups: "1 250.40". Never through a Float.
  def receipt_money(amount, currency = nil)
    return if amount.nil?

    [ number_with_precision(amount, precision: 2, delimiter: " "), currency ].compact.join(" ")
  end

  # A quantity without trailing zeros: 2, 1.25, 0.335.
  def receipt_quantity(quantity)
    number_with_precision(quantity, precision: 3, strip_insignificant_zeros: true) if quantity
  end

  # A time in Kyiv time (config.time_zone), to the minute.
  def receipt_time(time)
    return if time.nil?

    time_tag time, l(time.in_time_zone, format: "%Y-%m-%d %H:%M")
  end

  def receipt_confidence(confidence)
    number_to_percentage(confidence * 100, precision: 0) if confidence
  end

  # The value of one side of a QR comparison row, formatted for its field.
  def receipt_qr_value(field, value, currency = nil)
    return tag.span("—", class: "text-ink-muted") if value.nil?

    case field
    when :issued_at then receipt_time(value)
    when :total then receipt_money(value, currency)
    else value
    end
  end

  # The mark of a QR comparison row (Receipt::QrComparison::Row#state).
  def receipt_qr_mark(state)
    case state
    when :match then ui_badge(tone: :accent) { ui_icon("check", size: :xs) + "Match" }
    when :mismatch then ui_badge(tone: :danger) { ui_icon("x", size: :xs) + "Mismatch" }
    when :qr_only then ui_badge("OCR read nothing", tone: :muted)
    when :ocr_only then ui_badge("Not in the QR code", tone: :muted)
    end
  end

  # --- The review form -------------------------------------------------------------------------------------

  # The categories a person may choose, under their groups, in taxonomy order: [[group, [[name, id], ...]]].
  # The "Uncategorised" group is left out: no category is "not categorised yet" in this app, and the
  # history import's placeholder is not a choice to make by hand.
  def category_choices
    @category_choices ||= Category.groups.where.not(slug: Category::UNCATEGORISED_SLUG.split("/").first).ordered
      .includes(:children).filter_map do |group|
        children = group.children.map { |category| [ category.name, category.id ] }
        [ group.name, children ] if children.any?
      end
  end

  # The account select of a booking form: active accounts in `currency` first, then the others, each with its
  # currency.
  def account_choices(currency, selected)
    accounts = Account.active.order(:name).to_a
    own, other = currency ? accounts.partition { |account| account.currency == currency } : [ accounts, [] ]
    label = ->(account) { [ "#{account.name} (#{account.currency})", account.id ] }
    groups = [ [ (currency ? "In #{currency}" : "Accounts"), own.map(&label) ], [ "Other currencies", other.map(&label) ] ]
    grouped_options_for_select(groups.reject { |_, choices| choices.empty? }, selected&.id)
  end

  # The value of the date-and-time field: what the person typed while it is unsaved and unreadable, else the
  # stored moment in Kyiv time, to the second.
  def review_issued_at_value(receipt)
    raw = receipt.read_attribute_before_type_cast("issued_at")
    return raw if raw.is_a?(String) && receipt.issued_at.nil?

    receipt.issued_at&.in_time_zone&.strftime("%Y-%m-%dT%H:%M:%S")
  end

  # The QR ground truth of one header field with its mark, or nil when the QR code says nothing about it.
  # The comparison is with the saved value (Receipt::QrComparison); `copy` is the QR value as the field
  # takes it.
  QrField = Data.define(:field, :value, :state, :copy)

  def review_qr_fields(receipt)
    Receipt::QrComparison.new(receipt).rows.each_with_object({}) do |row, fields|
      next if row.qr.nil?

      copy = case row.field
      when :issued_at then row.qr.in_time_zone.strftime("%Y-%m-%dT%H:%M:%S")
      when :total then JsonFormat.money(row.qr)
      else row.qr.to_s
      end
      fields[row.field] = QrField.new(field: row.field, value: row.qr, state: row.state, copy:)
    end
  end

  # --- Ground truth ---------------------------------------------------------------------------------------

  GROUND_TRUTH_FIELD_LABELS = {
    "kind" => "Kind", "merchant" => "Merchant", "fiscal_number" => "Fiscal number", "receipt_number" => "Receipt number",
    "issued_at" => "Date and time", "total" => "Total", "currency" => "Currency", "card_last4" => "Card digits",
    "is_return" => "Return", "category_slug" => "Category"
  }.freeze
  GROUND_TRUTH_ITEM_LABELS = {
    "name" => "name", "quantity" => "quantity", "unit_price" => "unit price", "amount" => "amount",
    "discount" => "discount", "category_slug" => "category"
  }.freeze
  # The review form's field ids that "Fill the form from the tax-service record" writes, by document key.
  GROUND_TRUTH_FORM_FIELDS = {
    "kind" => "receipt_kind", "merchant" => "receipt_merchant_name", "issued_at" => "receipt_issued_at",
    "total" => "receipt_total", "currency" => "receipt_currency", "fiscal_number" => "receipt_fiscal_number",
    "receipt_number" => "receipt_receipt_number", "card_last4" => "receipt_card_last4"
  }.freeze

  # What filled the form a manual record was corrected from, in words.
  def ground_truth_prefill_label(record)
    case record.prefill_kind
    when :hand then "nothing (entered by hand)"
    when :dps_xml then "the tax-service record"
    when :model
      details = [ record.prefilled_model_version, ("prompt #{record.prefilled_prompt_version}" if record.prefilled_prompt_version) ].compact
      details.any? ? "#{record.prefilled_by} (#{details.join(', ')})" : record.prefilled_by
    end
  end

  def ground_truth_categoriser_label(record)
    return "no suggestions" if record.categories_prefilled_by.nil?
    return "suggestions of an unrecorded categoriser" if record.categories_prefilled_by == ReceiptGroundTruth::CATEGORISER_UNKNOWN

    record.categories_prefilled_by
  end

  # Small badges for a receipt's ground truth (the list and the receipt page): "By hand" for a manual record,
  # "Tax" for a tax-service record, with its check. `records` are the receipt's ReceiptGroundTruth rows.
  def ground_truth_badges(records)
    badges = records.sort_by(&:source).map do |record|
      if record.manual?
        ui_badge("By hand", tone: :accent, title: "Labelled by hand")
      elsif record.check_matches?
        ui_badge(tone: :solid, title: "Tax-service record, checked: matches the print") { ui_icon("check", size: :xs) + "Tax" }
      elsif record.check_differs?
        ui_badge(tone: :danger, title: "Tax-service record, checked: differs from the print") { ui_icon("x", size: :xs) + "Tax" }
      else
        ui_badge("Tax", tone: :neutral, title: "Tax-service record, not checked yet")
      end
    end
    safe_join(badges, " ")
  end

  # What replacing a manual record changes, in one sentence of counts (the confirmation of "Save as ground
  # truth"): the header fields that differ, the items changed, added and removed, and the record's own fields.
  def ground_truth_change_summary(result)
    diff = result.diff
    parts = []
    if diff.fields.any?
      names = diff.fields.map { |key| GROUND_TRUTH_FIELD_LABELS.fetch(key, key).downcase }
      parts << "#{pluralize(diff.fields.size, 'field')} (#{names.join(', ')})"
    end
    items = { "changed" => diff.items_changed, "added" => diff.items_added, "removed" => diff.items_removed }
      .select { |_, count| count.positive? }
    parts << "#{items.values.sum == 1 ? '1 item' : "#{items.values.sum} items"} (#{items.map { |what, count| "#{count} #{what}" }.join(', ')})" if items.any?
    parts << result.meta_changes.map { |key| Receipts::SaveGroundTruth::META_FIELDS.fetch(key) }.join(", ") if result.meta_changes.any?
    parts.any? ? "What changes: #{parts.join('; ')}." : "The document is the same; only its schema version changes."
  end

  # A document value for people: money and quantities as stored (decimal strings), a time in Kyiv time.
  def ground_truth_value(key, value)
    return tag.span("—", class: "text-ink-muted") if value.nil?

    case key
    when "issued_at" then receipt_time(Time.iso8601(value))
    when "kind" then KIND_LABELS.fetch(value, value)
    when "is_return" then value ? "Yes" : "No"
    else value.to_s
    end
  rescue ArgumentError
    value.to_s
  end

  # What "Fill the form from the tax-service record" writes: each header field by its id (an unknown value
  # empties the field, so nothing of the earlier answer stays) and the item rows, as the form takes them.
  def ground_truth_fill_data(record)
    document = record.current_document
    fields = GROUND_TRUTH_FORM_FIELDS.to_h do |key, id|
      value = document[key]
      value = Time.iso8601(value).in_time_zone.strftime("%Y-%m-%dT%H:%M:%S") if key == "issued_at" && value
      [ id, value.to_s ]
    end
    items = document["items"].map { |item| item.slice("name", "quantity", "unit_price", "discount", "amount").transform_values(&:to_s) }
    { fields:, items: }
  end

  # Why a transaction booked from a receipt needs review, or nil (Receipts::Accept.review_reasons).
  def transaction_review_reasons(transaction)
    return [] unless transaction.needs_review?

    lines = transaction.lines.map { |line| { category_id: line.category_id } }
    reasons = transaction.receipt ? Receipts::Accept.review_reasons(transaction.receipt, lines) : []
    reasons << "a line has no category" if reasons.empty? && lines.any? { |line| line[:category_id].nil? }
    reasons
  end
end
