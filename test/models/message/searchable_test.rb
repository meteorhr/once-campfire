require "test_helper"

class Message::SearchableTest < ActiveSupport::TestCase
  test "message body is indexed and searchable" do
    message = rooms(:designers).messages.create! body: "My hovercraft is full of eels", client_message_id: "earth", creator: users(:david)
    assert_equal [ message ], rooms(:designers).messages.search("eel")

    message.update! body: "My hovercraft is full of sharks"
    assert_equal [ message ], rooms(:designers).messages.search("sharks")

    message.destroy!
    assert_equal [], rooms(:designers).messages.search("sharks")
  end

  test "search results are returned in message order" do
    messages = [ "first cat", "second cat", "third cat", "cat cat cat" ].map do |body|
      rooms(:designers).messages.create! body: body, client_message_id: body, creator: users(:david)
    end

    assert_equal messages, rooms(:designers).messages.search("cat")
  end

  test "rich text body is converted to plain text for indexing" do
    message = rooms(:designers).messages.create! body: "<span>My hovercraft is full of eels</span>", client_message_id: "earth", creator: users(:david)

    assert_equal [], rooms(:designers).messages.search("span")
    assert_equal [ message ], rooms(:designers).messages.search("eel")
  end

  test "encrypted messages are excluded from the search index" do
    room = rooms(:david_and_jason)
    room.messages.create!(
      creator: users(:david),
      client_message_id: "enc-search",
      e2e_algorithm: Message::E2E_ALGORITHM,
      e2e_payload: {
        "v" => 1,
        "alg" => Message::E2E_ALGORITHM,
        "from" => users(:david).id,
        "to" => users(:jason).id,
        "c" => 0,
        "iv" => "aW5pdGlhbHZlY3Rvcg",
        "ciphertext" => "Y2lwaGVydGV4dA"
      }
    )

    assert_equal [], room.messages.search("ciphertext")
  end
end
