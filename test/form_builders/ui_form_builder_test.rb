require "test_helper"

class UiFormBuilderTest < ActionView::TestCase
  include UiHelper

  Record = Struct.new(:name, :kind, :active, keyword_init: true) do
    include ActiveModel::Model
    include ActiveModel::Validations

    validates :name, presence: true

    def persisted? = false
    def self.model_name = ActiveModel::Name.new(self, nil, "Record")
  end

  setup do
    @record = Record.new(name: "", kind: "cash", active: true)
  end

  def builder(object = @record)
    UiFormBuilder.new(:record, object, self, {})
  end

  test "text fields get form-control" do
    assert_match(/class="form-control"/, builder.text_field(:name))
    assert_match(/class="form-control h-12"/, builder.email_field(:name, class: "h-12"))
    assert_match(/class="form-control" type="password"/, builder.password_field(:name))
  end

  test "a file field gets form-control and its file modifier" do
    html = builder.file_field(:name, multiple: true)

    assert_match(/class="form-control form-control-file"/, html)
    assert_match(/multiple="multiple"/, html)
  end

  test "text area and select get their modifiers" do
    assert_match(/class="form-control form-control-textarea"/, builder.text_area(:name))
    select = builder.select(:kind, %w[cash card])
    assert_match(/<div class="form-select-wrapper"><select class="form-control form-control-select"/, select)
    assert_match(/<svg[^>]*class="h-4 w-4 form-select-chevron"/, select)
  end

  test "collection select is wrapped like select" do
    kind = Struct.new(:id, :label)
    kinds = [ kind.new("cash", "Cash"), kind.new("card", "Card") ]
    select = builder.collection_select(:kind, kinds, :id, :label)
    assert_match(/<div class="form-select-wrapper"><select class="form-control form-control-select"/, select)
    assert_match(/<option value="card">Card<\/option>/, select)
  end

  test "check box and radio get their classes" do
    assert_match(/class="form-check"/, builder.check_box(:active))
    assert_match(/class="form-check"/, builder.checkbox(:active))
    assert_match(/class="form-radio"/, builder.radio_button(:kind, "cash"))
  end

  test "submit and button use button classes" do
    assert_match(/class="btn btn-primary"/, builder.submit("Save"))
    assert_match(/class="btn btn-secondary btn-small"/, builder.button("Cancel", variant: :secondary, size: :sm))
  end

  test "invalid fields get aria-invalid and error text" do
    @record.validate
    assert_match(/aria-invalid="true"/, builder.text_field(:name))
    assert_dom_equal %(<p class="field-error">Name can't be blank</p>), builder.error_for(:name)
    assert_nil builder.error_for(:kind)
  end

  test "a form for a plain symbol, without an object that has errors, still renders" do
    plain = UiFormBuilder.new(:session, nil, self, {})
    assert_no_match(/aria-invalid/, plain.email_field(:email))
    assert_nil plain.error_for(:email)
  end

  test "hint renders helper text" do
    assert_dom_equal %(<p class="field-hint">Shown in lists.</p>), builder.hint("Shown in lists.")
  end
end
