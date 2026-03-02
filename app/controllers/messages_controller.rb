class MessagesController < ApplicationController
  include ActiveStorage::SetCurrent, RoomScoped

  class InvalidE2ePayload < StandardError; end

  before_action :set_room, except: :create
  before_action :set_message, only: %i[ show edit update destroy ]
  before_action :ensure_can_administer, only: %i[ edit update destroy ]
  before_action :ensure_message_editable, only: %i[ edit update ]

  layout false, only: :index

  def index
    @messages = find_paged_messages

    if @messages.any?
      fresh_when @messages
    else
      head :no_content
    end
  end

  def create
    set_room
    @message = nil

    Message.transaction do
      @message = @room.messages.create_with_attachment!(message_params)
      persist_e2e_message_envelopes!(@message) if @pending_e2e_envelopes.present?
    end

    @message.broadcast_create
    deliver_webhooks_to_bots
  rescue ActiveRecord::RecordNotFound
    render action: :room_not_found
  rescue ActiveRecord::RecordInvalid
    head :unprocessable_entity
  rescue ActionController::ParameterMissing, InvalidE2ePayload, JSON::ParserError
    head :unprocessable_entity
  end

  def show
  end

  def edit
  end

  def update
    @message.update!(message_params)

    @message.broadcast_replace_to @room, :messages, target: [ @message, :presentation ], partial: "messages/presentation", attributes: { maintain_scroll: true }
    redirect_to room_message_url(@room, @message)
  end

  def destroy
    @message.destroy
    @message.broadcast_remove
  end

  private
    def set_message
      @message = @room.messages.find(params[:id])
    end

    def ensure_can_administer
      head :forbidden unless Current.user.can_administer?(@message)
    end

    def ensure_message_editable
      head :unprocessable_entity unless @message.editable?
    end


    def find_paged_messages
      case
      when params[:before].present?
        @room.messages.with_creator.page_before(@room.messages.find(params[:before]))
      when params[:after].present?
        @room.messages.with_creator.page_after(@room.messages.find(params[:after]))
      else
        @room.messages.with_creator.last_page
      end
    end


    def message_params
      permitted = params.require(:message).permit(:body, :attachment, :client_message_id, :e2e_algorithm, :e2e_payload)
      return e2e_message_params_from(permitted) if encrypted_message_params?(permitted)

      permitted.except(:e2e_algorithm, :e2e_payload)
    end

    def encrypted_message_params?(permitted)
      permitted[:e2e_payload].present? || permitted[:e2e_algorithm].present?
    end

    def e2e_message_params_from(permitted)
      raise InvalidE2ePayload, "Encrypted messages are supported only in direct rooms" unless @room.direct?
      raise InvalidE2ePayload, "Attachment uploads cannot be sent as encrypted messages" if permitted[:attachment].present?

      algorithm = permitted[:e2e_algorithm].to_s
      raise InvalidE2ePayload, "Unsupported encryption algorithm" unless algorithm == Message::E2E_ALGORITHM

      payload = parse_e2e_payload(permitted[:e2e_payload])
      validate_e2e_payload!(payload)

      {
        client_message_id: permitted[:client_message_id],
        e2e_algorithm: algorithm,
        e2e_payload: payload
      }
    end

    def parse_e2e_payload(raw_payload)
      payload = raw_payload.is_a?(String) ? JSON.parse(raw_payload) : raw_payload
      payload.to_h.deep_stringify_keys
    end

    def validate_e2e_payload!(payload)
      raise InvalidE2ePayload, "Encrypted payload algorithm mismatch" unless payload["alg"] == Message::E2E_ALGORITHM
      raise InvalidE2ePayload, "Encrypted payload sender mismatch" unless payload["from"].to_i == Current.user.id

      recipient_id = @room.users.where.not(id: Current.user.id).pick(:id)
      raise InvalidE2ePayload, "Encrypted payload recipient mismatch" unless payload["to"].to_i == recipient_id

      if payload["envelopes"].present?
        validate_multi_device_payload!(payload, recipient_id)
      else
        validate_single_device_payload!(payload)
      end
    end

    def validate_single_device_payload!(payload)
      required_fields = %w[v alg from to c iv ciphertext]
      missing_fields = required_fields.select { |field| payload[field].blank? && payload[field] != 0 }
      raise InvalidE2ePayload, "Encrypted payload is missing required fields" if missing_fields.any?

      raise InvalidE2ePayload, "Encrypted payload counter must be a non-negative integer" unless payload["c"].to_i >= 0
      raise InvalidE2ePayload, "Encrypted payload IV must be base64url-encoded" unless base64url?(payload["iv"])
      raise InvalidE2ePayload, "Encrypted payload ciphertext must be base64url-encoded" unless base64url?(payload["ciphertext"])
    end

    def validate_multi_device_payload!(payload, recipient_id)
      required_fields = %w[v alg from to from_device_id envelopes]
      missing_fields = required_fields.select { |field| payload[field].blank? && payload[field] != 0 }
      raise InvalidE2ePayload, "Encrypted payload is missing required fields" if missing_fields.any?

      envelopes = Array(payload["envelopes"]).map { |envelope| envelope.to_h.deep_stringify_keys }
      raise InvalidE2ePayload, "Encrypted payload must include per-device envelopes" if envelopes.empty?

      sender_device = Current.user.e2e_devices.active.find_by(device_id: payload["from_device_id"])
      raise InvalidE2ePayload, "Encrypted payload sender device mismatch" unless sender_device

      allowed_recipient_user_ids = [ recipient_id, Current.user.id ]
      recipient_device_ids = envelopes.map { |envelope| envelope["recipient_device_id"].to_s }.reject(&:blank?).uniq
      recipient_devices = E2e::Device.active.where(user_id: allowed_recipient_user_ids, device_id: recipient_device_ids)
      recipient_devices_by_id = index_recipient_devices_by_id(recipient_devices)

      envelopes.each do |envelope|
        validate_envelope_payload!(envelope, payload, recipient_devices_by_id, allowed_recipient_user_ids)
      end

      ensure_unique_recipient_devices!(envelopes)
      ensure_peer_recipient_present!(envelopes, recipient_id)

      @pending_e2e_sender_device = sender_device
      @pending_e2e_recipient_devices = recipient_devices_by_id
      @pending_e2e_envelopes = envelopes
    end

    def validate_envelope_payload!(envelope, payload, recipient_devices_by_id, allowed_recipient_user_ids)
      required_fields = %w[sender_device_id recipient_device_id c iv ciphertext]
      missing_fields = required_fields.select { |field| envelope[field].blank? && envelope[field] != 0 }
      raise InvalidE2ePayload, "Encrypted envelope is missing required fields" if missing_fields.any?

      raise InvalidE2ePayload, "Encrypted envelope sender device mismatch" unless envelope["sender_device_id"].to_s == payload["from_device_id"].to_s
      recipient_device = recipient_devices_by_id[envelope["recipient_device_id"].to_s]
      raise InvalidE2ePayload, "Encrypted envelope recipient device mismatch" unless recipient_device

      explicit_recipient_user_id = integer_or_nil(envelope["recipient_user_id"])
      if envelope.key?("recipient_user_id") && explicit_recipient_user_id.nil?
        raise InvalidE2ePayload, "Encrypted envelope recipient user is invalid"
      end

      if explicit_recipient_user_id.present?
        unless allowed_recipient_user_ids.include?(explicit_recipient_user_id)
          raise InvalidE2ePayload, "Encrypted envelope recipient user mismatch"
        end

        unless recipient_device.user_id == explicit_recipient_user_id
          raise InvalidE2ePayload, "Encrypted envelope recipient user does not match recipient device"
        end
      end

      envelope["recipient_user_id"] = explicit_recipient_user_id || recipient_device.user_id
      raise InvalidE2ePayload, "Encrypted envelope counter must be a non-negative integer" unless envelope["c"].to_i >= 0
      raise InvalidE2ePayload, "Encrypted envelope IV must be base64url-encoded" unless base64url?(envelope["iv"])
      raise InvalidE2ePayload, "Encrypted envelope ciphertext must be base64url-encoded" unless base64url?(envelope["ciphertext"])
    end

    def index_recipient_devices_by_id(recipient_devices)
      grouped = recipient_devices.group_by(&:device_id)
      ambiguous = grouped.select { |_device_id, devices| devices.size > 1 }
      raise InvalidE2ePayload, "Encrypted payload has ambiguous recipient device identifiers" if ambiguous.any?

      grouped.transform_values(&:first)
    end

    def ensure_unique_recipient_devices!(envelopes)
      recipient_device_ids = envelopes.map { |envelope| envelope["recipient_device_id"].to_s }
      return if recipient_device_ids.uniq.length == recipient_device_ids.length

      raise InvalidE2ePayload, "Encrypted payload contains duplicate recipient devices"
    end

    def ensure_peer_recipient_present!(envelopes, recipient_id)
      return if envelopes.any? { |envelope| envelope["recipient_user_id"].to_i == recipient_id }

      raise InvalidE2ePayload, "Encrypted payload must include recipient peer device envelopes"
    end

    def persist_e2e_message_envelopes!(message)
      return if @pending_e2e_sender_device.blank?
      return if @pending_e2e_envelopes.blank?

      @pending_e2e_envelopes.each do |envelope|
        recipient_device = @pending_e2e_recipient_devices[envelope["recipient_device_id"].to_s]
        next unless recipient_device

        E2e::MessageEnvelope.create!(
          room: @room,
          sender_device: @pending_e2e_sender_device,
          recipient_device: recipient_device,
          client_message_id: message.client_message_id,
          algorithm: message.e2e_algorithm,
          header: {
            sender_device_id: envelope["sender_device_id"],
            recipient_device_id: envelope["recipient_device_id"],
            recipient_user_id: envelope["recipient_user_id"],
            c: envelope["c"],
            iv: envelope["iv"],
            x3dh: envelope["x3dh"]
          },
          ciphertext: envelope["ciphertext"]
        )
      end
    end

    def base64url?(value)
      value.to_s.match?(/\A[-_a-zA-Z0-9]+\z/)
    end

    def integer_or_nil(value)
      return nil if value.blank?

      Integer(value, exception: false)
    end


    def deliver_webhooks_to_bots
      return if @message.encrypted?

      bots_eligible_for_webhook.excluding(@message.creator).each { |bot| bot.deliver_webhook_later(@message) }
    end

    def bots_eligible_for_webhook
      @room.direct? ? @room.users.active_bots : @message.mentionees.active_bots
    end
end
