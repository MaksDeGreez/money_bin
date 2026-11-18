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

  # Why a transaction booked from a receipt needs review, or nil (Receipts::Accept.review_reasons).
  def transaction_review_reasons(transaction)
    return [] unless transaction.needs_review?

    lines = transaction.lines.map { |line| { category_id: line.category_id } }
    reasons = transaction.receipt ? Receipts::Accept.review_reasons(transaction.receipt, lines) : []
    reasons << "a line has no category" if reasons.empty? && lines.any? { |line| line[:category_id].nil? }
    reasons
  end
end
