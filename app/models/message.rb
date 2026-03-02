class Message < ApplicationRecord
  include Attachment, Broadcasts, Mentionee, Pagination, Searchable

  E2E_ALGORITHM = "double_ratchet_v1"

  belongs_to :room, touch: true
  belongs_to :creator, class_name: "User", default: -> { Current.user }

  has_many :boosts, dependent: :destroy

  has_rich_text :body

  validate :requires_content
  validate :requires_supported_e2e_algorithm

  before_create -> { self.client_message_id ||= Random.uuid } # Bots don't care
  after_create_commit -> { room.receive(self) }

  scope :ordered, -> { order(:created_at) }
  scope :with_creator, -> { preload(creator: :avatar_attachment) }
  scope :with_attachment_details, -> {
    with_rich_text_body_and_embeds
    with_attached_attachment
      .includes(attachment_blob: :variant_records)
  }
  scope :with_boosts, -> { includes(boosts: :booster) }

  def plain_text_body
    return "" if encrypted?

    body.to_plain_text.presence || attachment&.filename&.to_s || ""
  end

  def to_key
    [ client_message_id ]
  end

  def encrypted?
    encrypted_payload.present?
  end

  def editable?
    !encrypted?
  end

  def e2e_payload_hash
    case encrypted_payload
    when Hash
      encrypted_payload
    when String
      JSON.parse(encrypted_payload)
    else
      {}
    end
  rescue JSON::ParserError
    {}
  end

  def content_type
    case
    when encrypted?     then "encrypted"
    when attachment?    then "attachment"
    when sound.present? then "sound"
    else                     "text"
    end.inquiry
  end

  def sound
    plain_text_body.match(/\A\/play (?<name>\w+)\z/) do |match|
      Sound.find_by_name match[:name]
    end
  end

  private
    def requires_content
      return if attachment?
      return if encrypted?
      return if body.to_plain_text.present?

      errors.add(:base, "Message must include body, attachment, or encrypted payload")
    end

    def requires_supported_e2e_algorithm
      return unless encrypted?
      return if encryption_algorithm == E2E_ALGORITHM

      errors.add(:e2e_algorithm, "must be #{E2E_ALGORITHM}")
    end

    def encrypted_payload
      self.attributes["e2e_payload"]
    end

    def encryption_algorithm
      self.attributes["e2e_algorithm"]
    end
end
