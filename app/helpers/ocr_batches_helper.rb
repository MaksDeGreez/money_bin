# Labels and small pieces of the OCR batch pages. Tones are symbols of UiHelper::BADGE_TONES.
module OcrBatchesHelper
  STATE_LABELS = {
    "pending" => "Waiting to be sent", "submitting" => "Sending", "running" => "At the provider",
    "applying" => "Storing results", "finished" => "Finished", "failed" => "Failed", "unknown" => "Outcome unknown"
  }.freeze
  STATE_TONES = {
    "pending" => :neutral, "submitting" => :signal, "running" => :signal, "applying" => :signal,
    "finished" => :solid, "failed" => :danger, "unknown" => :danger
  }.freeze
  ENTRY_LABELS = {
    "waiting" => "Waiting", "applied" => "Read", "sync_queued" => "Read one at a time",
    "failed" => "Failed", "released" => "Released", "superseded" => "Taken over by a person"
  }.freeze
  DELETION_LABELS = {
    "deleted" => "Deleted at OpenRouter and at the provider",
    "unsupported" => "Deleted at OpenRouter; the provider keeps its copy under its own retention rules",
    "not_applicable" => "Deleted at OpenRouter",
    "gone" => "OpenRouter no longer had it"
  }.freeze

  def ocr_batch_state_badge(batch)
    ui_badge STATE_LABELS.fetch(batch.state), tone: STATE_TONES.fetch(batch.state)
  end

  def ocr_batch_entry_label(state)
    ENTRY_LABELS.fetch(state)
  end

  def ocr_batch_deletion_label(batch)
    if batch.deleted_upstream_at
      DELETION_LABELS.fetch(batch.upstream_deletion)
    elsif batch.provider_batch_id.nil?
      "Never sent to the provider"
    elsif batch.awaiting_deletion?
      "Not deleted yet: the next check deletes it"
    else
      "Kept by the provider until it is finished and deleted (at most 30 days)"
    end
  end

  # US dollars with every digit the provider reported ("$0.000123"), never through a Float.
  def ocr_batch_usd(amount)
    return if amount.nil?

    "$#{amount.to_d.to_s('F').sub(/\.0\z/, '')}"
  end

  # An estimate, rounded up to a cent-friendly figure for reading ("about $1.23"); the exact value is the title.
  def ocr_batch_estimate(amount)
    return if amount.nil?

    rounded = amount.to_d.round(amount < 1 ? 4 : 2, BigDecimal::ROUND_UP)
    tag.span("about $#{rounded.to_s('F')}", title: ocr_batch_usd(amount))
  end

  def ocr_batch_counts(batch)
    return if batch.requests_total.nil?

    "#{batch.requests_completed || 0} done, #{batch.requests_failed || 0} failed of #{batch.requests_total}"
  end
end
