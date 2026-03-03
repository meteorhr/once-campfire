module SetLocale
  extend ActiveSupport::Concern

  included do
    before_action :set_locale
  end

  private
    def set_locale
      I18n.locale = locale_from_browser || I18n.default_locale
    end

    def locale_from_browser
      supported_locales = I18n.available_locales.map(&:to_s)

      preferred_locales.each do |requested_locale|
        normalized = normalize_locale(requested_locale)
        return normalized.to_sym if supported_locales.include?(normalized)
      end

      nil
    end

    def preferred_locales
      request.get_header("HTTP_ACCEPT_LANGUAGE").to_s.split(",").filter_map do |entry|
        locale, quality = entry.strip.split(";q=", 2)
        next if locale.blank? || locale == "*"

        [ locale, quality ? quality.to_f : 1.0 ]
      end.sort_by { |(_, quality)| -quality }.map(&:first)
    end

    def normalize_locale(locale)
      candidate = locale.to_s.tr("_", "-").downcase
      return "pt-BR" if candidate.start_with?("pt")

      candidate.split("-").first
    end
end
