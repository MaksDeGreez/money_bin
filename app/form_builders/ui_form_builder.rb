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

  # A text field for money (or, with `places: 3`, a quantity), typed as text so a comma can be the decimal
  # separator (MoneyInput reads it). It shows what the person typed while the value is unsaved (after a
  # refused save), and the stored decimal otherwise, written exactly: "40.40", or "0.335" for a quantity
  # (trailing zeros dropped). Never through a Float.
  #
  #   = f.money_field :amount, "aria-label": "Amount"
  def money_field(method, options = {})
    options = options.dup
    places = options.delete(:places) || Transaction::MONEY_DECIMAL_PLACES
    options[:value] = decimal_text(method, places) unless options.key?(:value)
    options[:inputmode] ||= "decimal"
    options[:autocomplete] ||= "off"
    options[:class] = @template.ui_classes("form-control-num", options[:class])
    text_field(method, options)
  end

  # A category picker for a `category_id`: a native select of the categories under their groups, which is
  # what the form submits (so only a category, never free text, can be sent), driven by a type-to-filter
  # combobox (combobox_controller.js; the `.combobox` classes in design-system.css). The select is hidden
  # and out of the tab order; the text field in front of it is what a person types into.
  #
  #   = f.category_select :category_id, groups, "aria-label": "Category of item 3", suggestion: item.suggested_category
  #
  # `groups` is [[group name, [[category name, id], ...]], ...] (ReceiptsHelper#category_choices).
  # `suggestion` (a Category) is offered first and taken with Enter in an empty field.
  def category_select(method, groups, options = {})
    options = options.dup
    suggestion = options.delete(:suggestion)
    label = options.delete(:"aria-label") || options.delete(:aria_label)
    selected = object.public_send(method)
    selected_name = groups.flat_map(&:last).find { |_, id| id.to_s == selected.to_s }&.first if selected.present?
    select_id = options[:id] || field_id(method)
    invalid = errors_for(method).any?

    @template.tag.div(class: @template.ui_classes("combobox", options.delete(:class)), data: {
      controller: "combobox", combobox_suggestion_value: suggestion&.id, combobox_suggestion_label_value: suggestion&.name
    }) do
      choices = @template.grouped_options_for_select(groups, selected)
      @template.safe_join([
        @template.tag.input(type: "text", value: selected_name, class: "form-control combobox-input",
          role: "combobox", autocomplete: "off", spellcheck: "false", placeholder: "Type to choose",
          aria: { label:, autocomplete: "list", expanded: "false", controls: "#{select_id}_listbox", invalid: (invalid || nil) },
          data: { combobox_target: "input", action: "focus->combobox#focus input->combobox#filter keydown->combobox#keydown blur->combobox#blur" }),
        @template.tag.ul(id: "#{select_id}_listbox", role: "listbox", class: "combobox-listbox", hidden: true,
          aria: { label: }, data: { combobox_target: "listbox" }),
        ActionView::Helpers::FormBuilder.instance_method(:select).bind_call(self, method,
          @template.tag.option("No category", value: "") + choices, {},
          { id: select_id, hidden: true, tabindex: -1, aria: { hidden: true },
            data: { combobox_target: "select", action: "change->combobox#sync" } })
      ])
    end
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

  # The value of a decimal attribute as text for a field: the typed text while it is unsaved, else the
  # stored decimal, written exactly. A refused value counts as typed even when its cast equals the stored
  # one ("60.004" casts to the column's 60.00, so the record sees no change).
  def decimal_text(method, places)
    if object.respond_to?(:read_attribute_before_type_cast)
      raw = object.read_attribute_before_type_cast(method.to_s)
      typed = object.attribute_changed?(method) || object.errors.include?(method)
      return raw if raw.is_a?(String) && typed

      value = object.public_send(method)
      return "" if value.nil?
      return JsonFormat.money(value) if places == Transaction::MONEY_DECIMAL_PLACES

      @template.number_with_precision(value, precision: places, strip_insignificant_zeros: true)
    else
      object.public_send(method).to_s
    end
  end

  def wrap_select(select_html)
    @template.tag.div(class: "form-select-wrapper") do
      select_html + @template.ui_icon("chevron-down", class: "form-select-chevron")
    end
  end
end
