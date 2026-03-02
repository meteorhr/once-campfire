module RoomsHelper
  def link_to_room(room, **attributes, &)
    classes = Array(attributes.delete(:class)).compact
    current_room_id = @room&.id || params[:room_id]&.to_i || last_room_visited&.id
    current_room = current_room_id == room.id
    classes << "room--current" if current_room

    aria_attributes = (attributes.delete(:aria) || {}).dup
    aria_attributes[:current] = "page" if current_room

    link_to room_path(room), **attributes, data: {
      rooms_list_target: "room", room_id: room.id, badge_dot_target: "unread", sorted_list_target: "item"
    }.merge(attributes.delete(:data) || {}), class: classes, aria: aria_attributes.presence, &
  end

  def link_to_edit_room(room, &)
    link_to \
      [ :edit, @room ],
      class: "btn",
      style: "view-transition-name: edit-room-#{@room.id}",
      data: { room_id: @room.id },
      &
  end

  def link_back_to_last_room_visited
    if last_room = last_room_visited
      link_back_to room_path(last_room)
    else
      link_back_to root_path
    end
  end

  def button_to_delete_room(room, url: nil)
    button_to url || room_url(room), method: :delete, class: "btn btn--negative max-width", aria: { label: "Delete #{room.name}" },
        data: { turbo_confirm: "Are you sure you want to delete this room and all messages in it? This can’t be undone." } do
      image_tag("trash.svg", aria: { hidden: "true" }, size: 20) +
      tag.span(room_display_name(room), class: "overflow-ellipsis")
    end
  end

  def button_to_jump_to_newest_message
    tag.button \
        class: "message-area__return-to-latest btn",
        data: { action: "messages#returnToLatest", messages_target: "latest" },
        hidden: true do
      image_tag("arrow-down.svg", aria: { hidden: "true" }, size: 20) +
      tag.span("Jump to newest message", class: "for-screen-reader")
    end
  end

  def submit_room_button_tag
    button_tag class: "btn btn--reversed txt-large center", type: "submit" do
      image_tag("check.svg", aria: { hidden: "true" }, size: 20) +
      tag.span("Save", class: "for-screen-reader")
    end
  end

  def composer_form_tag(room, &)
    form_with model: Message.new, url: room_messages_path(room),
      id: "composer", class: "margin-block flex-item-grow contain", data: composer_data_options(room), &
  end

  def room_display_name(room, for_user: Current.user)
    if room.direct?
      room.users.without(for_user).pluck(:name).to_sentence.presence || for_user&.name
    else
      room.name
    end
  end

  private
    def composer_data_options(room)
      peer_user = room.direct? ? room.users.without(Current.user).first : nil

      {
        controller: "composer drop-target",
        action: composer_data_actions,
        composer_messages_outlet: "#message-area",
        composer_toolbar_class: "composer--rich-text",
        composer_room_id_value: room.id,
        composer_e2e_enabled_value: room.direct?,
        composer_e2e_peer_user_id_value: peer_user&.id,
        composer_e2e_device_url_value: user_e2e_device_path,
        composer_e2e_prekey_bundle_url_value: (peer_user ? user_e2e_prekey_bundle_path(peer_user, room_id: room.id) : nil),
        composer_e2e_self_prekey_bundle_url_value: (room.direct? ? user_e2e_prekey_bundle_path(user_id: "me", room_id: room.id, self_sync: true) : nil)
      }
    end

    def composer_data_actions
      drag_and_drop_actions = "drop-target:drop@window->composer#dropFiles"

      trix_attachment_actions =
        "trix-file-accept->composer#preventAttachment refresh-room:online@window->composer#online"

      remaining_actions =
        "typing-notifications#stop paste->composer#pasteFiles turbo:submit-end->composer#submitEnd refresh-room:offline@window->composer#offline"

      [ drop_target_actions, drag_and_drop_actions, trix_attachment_actions, remaining_actions ].join(" ")
    end
end
