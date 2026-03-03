module TranslationsHelper
  def translation_hint(translation_key)
    I18n.t(translation_key, scope: :translation_hints)
  end
end
