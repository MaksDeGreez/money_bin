require "test_helper"

class UiHelperTest < ActionView::TestCase
  include UiHelper

  test "ui_button renders variant and size classes" do
    html = ui_button("Save", variant: :secondary, size: :sm, data: { action: "dialog#open" })
    assert_dom_equal %(<button type="button" class="btn btn-secondary btn-small" data-action="dialog#open">Save</button>), html
  end

  test "ui_button takes a block" do
    html = ui_button(variant: :ghost, size: :icon, "aria-label": "Close") { "x" }
    assert_dom_equal %(<button type="button" class="btn btn-ghost btn-icon" aria-label="Close">x</button>), html
  end

  test "ui_button merges caller classes and resolves utility conflicts" do
    assert_equal "btn btn-primary h-12", ui_button_classes(class: "h-12")
  end

  test "ui_button rejects unknown variants" do
    assert_raises(KeyError) { ui_button("x", variant: :fancy) }
  end

  test "ui_link_button renders a link with button classes, with a label or a block" do
    assert_dom_equal %(<a class="btn btn-ghost" href="/x">Go</a>), ui_link_button("Go", "/x", variant: :ghost)
    assert_dom_equal %(<a class="btn btn-primary" href="/y">Next</a>), ui_link_button("/y") { "Next" }
  end

  test "ui_button_to renders a form with a styled button, with a label or a block" do
    form = ui_button_to("Delete", "/items/1", variant: :danger, method: :delete)
    assert_match(/<form class="button_to" method="post" action="\/items\/1">/, form)
    assert_match(/name="_method" value="delete"/, form)
    assert_match(/<button class="btn btn-danger" type="submit">Delete<\/button>/, form)

    form = ui_button_to("/items/2", variant: :secondary) { "Archive" }
    assert_match(/action="\/items\/2"/, form)
    assert_match(/<button class="btn btn-secondary" type="submit">Archive<\/button>/, form)
  end

  test "ui_badge renders tones" do
    assert_dom_equal %(<span class="badge badge-signal">Due</span>), ui_badge("Due", tone: :signal)
    assert_dom_equal %(<span class="badge badge-danger">Failed</span>), ui_badge("Failed", tone: :danger)
  end

  test "ui_icon renders an inline lucide svg at the requested size" do
    html = ui_icon("folder", size: :md)
    assert_match(/<svg[^>]*class="h-5 w-5"/, html)
    assert_match(/aria-hidden="true"/, html)
  end

  test "ui_flash_tone maps flash keys" do
    assert_equal :accent, ui_flash_tone(:notice)
    assert_equal :accent, ui_flash_tone("success")
    assert_equal :danger, ui_flash_tone("alert")
    assert_equal :signal, ui_flash_tone(:warning)
    assert_equal :neutral, ui_flash_tone(:other)
  end

  test "ui_kbd renders each key as a key cap" do
    html = ui_kbd("Ctrl", "S", class: "hidden")

    assert_dom_equal '<span class="kbd-group hidden"><kbd class="kbd">Ctrl</kbd><kbd class="kbd">S</kbd></span>', html
  end
end
