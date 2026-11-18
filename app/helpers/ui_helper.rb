# UI primitives. Views use these to draw buttons, badges and icons, so every page looks the same.
#
# The variant maps hold complete class names. Component classes (btn-*, badge-*) are plain CSS in
# app/assets/tailwind/design-system.css, so they are always in the build. Tailwind utilities are
# different: they must appear as whole words in a scanned file, so never build them from pieces.
module UiHelper
  include LucideRails::RailsHelper

  BUTTON_VARIANTS = {
    primary: "btn-primary",
    secondary: "btn-secondary",
    ghost: "btn-ghost",
    soft: "btn-soft",
    danger: "btn-danger",
    link: "btn-link"
  }.freeze

  BUTTON_SIZES = {
    sm: "btn-small",
    md: nil,
    lg: "btn-large",
    icon: "btn-icon"
  }.freeze

  BADGE_TONES = {
    neutral: "badge-neutral",
    accent: "badge-accent",
    signal: "badge-signal",
    muted: "badge-muted",
    solid: "badge-solid",
    danger: "badge-danger"
  }.freeze

  CALLOUT_TONES = {
    neutral: nil,
    accent: "callout-accent",
    signal: "callout-signal",
    danger: "callout-danger"
  }.freeze

  ICON_SIZES = {
    xs: "h-3.5 w-3.5",
    sm: "h-4 w-4",   # inline with text, inside buttons
    md: "h-5 w-5",   # standalone
    lg: "h-6 w-6"    # page headers, empty states
  }.freeze

  # Joins class lists and resolves conflicting Tailwind utilities, so a caller's
  # `class: "h-12"` replaces a component's `h-10` instead of fighting it.
  def ui_classes(*classes)
    TAILWIND_MERGER.merge(token_list(*classes))
  end

  # Class string for a button. Use it with link_to, button_to or f.submit when the
  # ui_button helpers do not fit.
  def ui_button_classes(variant: :primary, size: :md, **options)
    ui_classes("btn", BUTTON_VARIANTS.fetch(variant), BUTTON_SIZES.fetch(size), options[:class])
  end

  # A <button>. Pass a label or a block (for an icon and text).
  #
  #   = ui_button "Save", variant: :primary
  #   = ui_button variant: :ghost, size: :icon, "aria-label": "Close" do
  #     = ui_icon "x"
  def ui_button(label = nil, variant: :primary, size: :md, type: "button", **attrs, &block)
    classes = ui_button_classes(variant:, size:, class: attrs.delete(:class))
    tag.button(label, type:, class: classes, **attrs, &block)
  end

  # A link that looks like a button.
  def ui_link_button(label = nil, path = nil, variant: :primary, size: :md, **attrs, &block)
    classes = ui_button_classes(variant:, size:, class: attrs.delete(:class))
    if block
      link_to(label, class: classes, **attrs, &block)
    else
      link_to(label, path, class: classes, **attrs)
    end
  end

  # A button that submits a small form (POST, PATCH or DELETE) and looks like a button.
  def ui_button_to(label = nil, path = nil, variant: :primary, size: :md, **attrs, &block)
    classes = ui_button_classes(variant:, size:, class: attrs.delete(:class))
    if block
      button_to(label || path, { class: classes, **attrs }, &block)
    else
      button_to(label, path, { class: classes, **attrs })
    end
  end

  def ui_badge(text = nil, tone: :neutral, **attrs, &block)
    classes = ui_classes("badge", BADGE_TONES.fetch(tone), attrs.delete(:class))
    tag.span(text, class: classes, **attrs, &block)
  end

  # A Lucide icon as inline SVG. Icons are decorative by default (aria-hidden).
  #
  #   = ui_icon "folder"                     # 16px, inline
  #   = ui_icon "settings", size: :md        # 20px
  #   = ui_icon "ellipsis", size: :lg, "stroke-width": 1.5
  def ui_icon(name, size: :sm, **attrs)
    classes = ui_classes(ICON_SIZES.fetch(size), attrs.delete(:class))
    lucide_icon(name.to_s, class: classes, **attrs)
  end

  # A keyboard shortcut, as a key cap: `ui_kbd "Ctrl", "S"` renders "Ctrl S" with each key boxed.
  def ui_kbd(*keys, **attrs)
    classes = ui_classes("kbd-group", attrs.delete(:class))
    tag.span(class: classes, **attrs) { safe_join(keys.map { |key| tag.kbd(key, class: "kbd") }) }
  end

  # Flash keys mapped to callout tones.
  def ui_flash_tone(key)
    case key.to_s
    when "notice", "success" then :accent
    when "alert", "error" then :danger
    when "warning" then :signal
    else :neutral
    end
  end

  TAILWIND_MERGER = TailwindMerge::Merger.new
  private_constant :TAILWIND_MERGER
end
