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
end
