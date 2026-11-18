require "test_helper"

class UiPartialsTest < ActionView::TestCase
  helper UiHelper

  test "flash messages become callouts with a tone per key, and blank ones are skipped" do
    flash[:notice] = "Saved."
    flash[:alert] = "Could not save."
    flash[:warning] = ""

    render partial: "ui/flash"

    assert_select "[role=status] .callout.callout-accent p", "Saved."
    assert_select "[role=status] .callout.callout-danger p", "Could not save."
    assert_select "[role=status]", 2
  end

  test "the page header shows the title, the description and the actions block" do
    render("ui/page_header", title: "Receipts", description: "Photos waiting to be read.") { "Upload" }

    assert_select "header.page-header h1", "Receipts"
    assert_select "header.page-header p", "Photos waiting to be read."
    assert_select ".page-header-actions", "Upload"
  end

  test "the page header works without a description or actions" do
    render partial: "ui/page_header", locals: { title: "Receipts" }

    assert_select "h1", "Receipts"
    assert_select "header p", 0
    assert_select ".page-header-actions", 0
  end

  test "pagination links to the neighbouring pages through the given URL builder" do
    pagination = Pagination.new(Receipt.order(:id), page: 2, per_page: 1)

    render partial: "ui/pagination", locals: { pagination:, url: ->(page) { "/things?page=#{page}" } }

    assert_select "nav.pagination[aria-label=Pages]"
    assert_select "a[rel=prev][href=?]", "/things?page=1", text: /Previous/
    assert_select "a[rel=next][href=?]", "/things?page=3", text: /Next/
    assert_select "p", text: /2–2 of #{Receipt.count}/
  end

  test "pagination disables the missing direction and is left out for one page" do
    render partial: "ui/pagination", locals: { pagination: Pagination.new(Receipt.order(:id), page: 1, per_page: 1), url: ->(page) { "/p/#{page}" } }
    assert_select "button[disabled]", text: /Previous/
    assert_select "a[rel=next]"

    render partial: "ui/pagination", locals: { pagination: Pagination.new(Receipt.none, page: 1), url: ->(page) { "/p/#{page}" } }
    assert_empty rendered.strip
  end

  test "count tabs link each value with its count and mark the current one" do
    render partial: "ui/count_tabs", locals: { label: "Status", tabs: [
      { label: "All", count: 1200, url: "/r", current: false },
      { label: "Failed", count: 3, url: "/r?status=failed", current: true }
    ] }

    assert_select "nav.count-tabs[aria-label=Status] a.count-tab", 2
    assert_select "a[href='/r']", text: /All\s*1 200/
    assert_select "a[aria-current=page][href='/r?status=failed']", text: /Failed\s*3/
  end

  test "count tabs without counts show only their labels" do
    render partial: "ui/count_tabs", locals: { label: "Show", tabs: [ { label: "Categories", url: "/", current: true }, { label: "Groups", url: "/?by=group" } ] }

    assert_select "a.count-tab", 2
    assert_select ".count-tab-number", 0
  end

  test "a callout can start hidden and carry data attributes" do
    render("ui/callout", tone: :signal, hidden: true, data: { form_guard_target: "notice" }) { "Changed elsewhere." }

    assert_select ".callout.callout-signal[hidden][data-form-guard-target=notice]", "Changed elsewhere."
  end

  test "the totals footer shows its figures with their targets, a status line, the note and the buttons" do
    figures = [ { label: "Items", value: "152.50 UAH", target: "sum" },
                { label: "Difference", value: "0.00 UAH", target: "difference", hidden: true, data: { receipt_review_target: "itemsOnly" } } ]
    render("ui/totals_footer", figures:, note: "Enter adds a row.") { "Save" }

    assert_select ".totals-footer" do
      assert_select ".totals-figure dt", "Items"
      assert_select ".totals-figure dd[data-money-totals-target=sum]", "152.50 UAH"
      assert_select ".totals-figure[hidden][data-receipt-review-target=itemsOnly] dd[data-money-totals-target=difference]"
      assert_select "p.totals-status[role=status][data-money-totals-target=status]"
      assert_select ".totals-actions", /Save/
      assert_select "p.totals-note", "Enter adds a row."
    end
  end
end
