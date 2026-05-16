defmodule SymphonyElixir.Linear.FileUploadTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Linear.FileUpload

  describe "content_type_for/1" do
    test "maps known extensions" do
      assert FileUpload.content_type_for("a.png") == "image/png"
      assert FileUpload.content_type_for("a.jpg") == "image/jpeg"
      assert FileUpload.content_type_for("a.jpeg") == "image/jpeg"
      assert FileUpload.content_type_for("a.gif") == "image/gif"
      assert FileUpload.content_type_for("a.webm") == "video/webm"
      assert FileUpload.content_type_for("a.mp4") == "video/mp4"
      assert FileUpload.content_type_for("a.md") == "text/markdown"
      assert FileUpload.content_type_for("a.json") == "application/json"
      assert FileUpload.content_type_for("a.txt") == "text/plain"
      assert FileUpload.content_type_for("a.log") == "text/plain"
      assert FileUpload.content_type_for("session.zip") == "application/zip"
    end

    test "case-insensitive on extension" do
      assert FileUpload.content_type_for("FOO.ZIP") == "application/zip"
      assert FileUpload.content_type_for("Foo.PNG") == "image/png"
    end

    test "falls back to octet-stream for unknown extensions" do
      assert FileUpload.content_type_for("foo.unknown") == "application/octet-stream"
      assert FileUpload.content_type_for("noext") == "application/octet-stream"
    end
  end
end
