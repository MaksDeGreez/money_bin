# Default form builder (see ApplicationController). Every field gets the
# design-system classes, an aria-invalid flag when the attribute has errors,
# and `f.error_for` / `f.hint` helpers for the text under a field.
#
#   = form_with model: @record do |f|
#     .field
#       = f.label :name
#       = f.text_field :name, placeholder: "Groceries"
#       = f.hint "Shown in lists."
#       = f.error_for :name
#     = f.submit "Save"
class UiFormBuilder < ActionView::Helpers::FormBuilder
  TEXT_FIELDS = %i[
    text_field email_field password_field number_field date_field time_field
    datetime_field month_field week_field url_field telephone_field phone_field
    search_field color_field
  ].freeze

  TEXT_FIELDS.each do |field|
    define_method(field) do |method, options = {}|
      super(method, control_options(method, options, "form-control"))
    end
  end

  def text_area(method, options = {})
    super(method, control_options(method, options, "form-control form-control-textarea"))
  end

  def select(method, choices = nil, options = {}, html_options = {}, &block)
    html_options = control_options(method, html_options, "form-control form-control-select")
    wrap_select(super(method, choices, options, html_options, &block))
  end

  def collection_select(method, collection, value_method, text_method, options = {}, html_options = {})
    html_options = control_options(method, html_options, "form-control form-control-select")
    wrap_select(super)
  end

  # A file picker. `multiple: true` for a has_many_attached attribute.
  def file_field(method, options = {})
    super(method, control_options(method, options, "form-control form-control-file"))
  end

  def check_box(method, options = {}, checked_value = "1", unchecked_value = "0")
    super(method, control_options(method, options, "form-check"), checked_value, unchecked_value)
  end
  alias checkbox check_box

  def radio_button(method, tag_value, options = {})
    super(method, tag_value, control_options(method, options, "form-radio"))
  end

  def submit(value = nil, options = {})
    options = options.dup
    options[:class] = @template.ui_button_classes(
      variant: options.delete(:variant) || :primary,
      size: options.delete(:size) || :md,
      class: options[:class]
    )
    super(value, options)
  end

  def button(value = nil, options = {}, &block)
    options = options.dup
    options[:class] = @template.ui_button_classes(
      variant: options.delete(:variant) || :primary,
      size: options.delete(:size) || :md,
      class: options[:class]
    )
    super(value, options, &block)
  end

  # Helper text under a field.
  def hint(text)
    @template.tag.p(text, class: "field-hint")
  end

  # First validation message for the attribute, or nothing.
  def error_for(method)
    message = errors_for(method).first
    @template.tag.p(message, class: "field-error") if message
  end

  private

  def control_options(method, options, base_classes)
    options = options.dup
    options[:class] = @template.ui_classes(base_classes, options[:class])
    options["aria-invalid"] = true if errors_for(method).any?
    options
  end

  def errors_for(method)
    return [] unless object.respond_to?(:errors)

    object.errors.full_messages_for(method)
  end

  def wrap_select(select_html)
    @template.tag.div(class: "form-select-wrapper") do
      select_html + @template.ui_icon("chevron-down", class: "form-select-chevron")
    end
  end
end
