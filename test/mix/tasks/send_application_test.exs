defmodule Mix.Tasks.Send.ApplicationTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureIO

  alias Mix.Tasks.Send.Application, as: SendApplication

  describe "prompt_nonempty/1" do
    test "returns the first nonempty input, skipping blank lines, up to 3 tries" do
      # First two inputs are blank, third is "Charlotte"
      user_input = "\n  \nCharlotte\n"
      prompt = "Enter name: "

      result =
        capture_io(user_input, fn ->
          assert SendApplication.prompt_nonempty(prompt) == "Charlotte"
        end)

      # The captured output should include warnings about empty inputs
      assert result =~ "→ Cannot be empty. You have 2 attempt(s) left."
      assert result =~ "→ Cannot be empty. You have 1 attempt(s) left."
    end

    test "raises after 3 blank attempts" do
      user_input = "\n\n\n"
      prompt = "Enter name: "

      assert_raise Mix.Error, fn ->
        capture_io(user_input, fn ->
          SendApplication.prompt_nonempty(prompt)
        end)
      end
    end
  end

  describe "prompt_email/1" do
    test "accepts a valid email on first try" do
      input = "user@example.com\n"
      prompt = "Enter email: "

      result =
        capture_io(input, fn ->
          assert SendApplication.prompt_email(prompt) == "user@example.com"
        end)

      # No “invalid format” message should appear
      refute result =~ "Invalid email format"
    end

    test "rejects invalid emails and accepts a valid one by third try" do
      # First two inputs invalid, third is valid
      user_input = "111\n222\nhello@example.com\n"
      prompt = "Enter email: "

      result =
        capture_io(user_input, fn ->
          assert SendApplication.prompt_email(prompt) == "hello@example.com"
        end)

      assert result =~ "Invalid email format. You have 2 attempt(s) left."
      assert result =~ "Invalid email format. You have 1 attempt(s) left."
    end

    test "raises after 3 invalid email attempts" do
      user_input = "bad\nworse\nworst\n"
      prompt = "Enter email: "

      assert_raise Mix.Error, fn ->
        capture_io(user_input, fn ->
          SendApplication.prompt_email(prompt)
        end)
      end
    end
  end

  describe "prompt_yes_no/1" do
    test "returns true on 'y' and false on 'n'" do
      # First scenario: user types "y\n"
      assert capture_io("y\n", fn ->
               assert SendApplication.prompt_yes_no("Confirm? (y/n): ") == true
             end) =~ ""

      # Second scenario: user types "n\n"
      assert capture_io("n\n", fn ->
               assert SendApplication.prompt_yes_no("Confirm? (y/n): ") == false
             end) =~ ""
    end

    test "rejects invalid entries and then accepts on second try" do
      # First input is "maybe\n", second is "N\n" (case‐insensitive)
      user_input = "maybe\nN\n"

      result =
        capture_io(user_input, fn ->
          assert SendApplication.prompt_yes_no("Confirm? (y/n): ") == false
        end)

      assert result =~ "→ Please type \"y\" or \"n\". You have 2 attempt(s) left."
    end

    test "raises after 3 invalid attempts" do
      user_input = "x\nz\n123\n"

      assert_raise Mix.Error, fn ->
        capture_io(user_input, fn ->
          SendApplication.prompt_yes_no("Confirm? (y/n): ")
        end)
      end
    end
  end

  describe "prompt_valid_json_key/1" do
    test "accepts a single valid key on first try" do
      input = "my_key\n"
      prompt = "Enter key: "

      result =
        capture_io(input, fn ->
          assert SendApplication.prompt_valid_json_key(prompt) == "my_key"
        end)

      refute result =~ "Invalid key"
      refute result =~ "Key cannot be empty"
    end

    test "rejects empty then invalid then accepts valid" do
      user_input = "\n inv\"alid \nz_key\n"
      prompt = "Enter key: "

      result =
        capture_io(user_input, fn ->
          assert SendApplication.prompt_valid_json_key(prompt) == "z_key"
        end)

      # After first blank:
      assert result =~ "→ Key cannot be empty. You have 2 attempt(s) left."

      # After invalid due to quote:
      assert result =~
               "→ Invalid key. Must not contain control chars or double‐quotes. You have 1 attempt(s) left."
    end

    test "raises after 3 invalid key attempts" do
      # blank, invalid (contains quote), blank
      user_input = "\n\"\n\n"
      prompt = "Enter key: "

      assert_raise Mix.Error, fn ->
        capture_io(user_input, fn ->
          SendApplication.prompt_valid_json_key(prompt)
        end)
      end
    end
  end

  describe "do_gather_extra_info/2 (via gather_extra_info/0)" do
    test "collects one custom field then stops when user says 'n'" do
      # Sequence: user says "y" to add field,
      #   enters valid key "age", enters valid value "30",
      #   then says "n" to stop.
      user_input = "y\nage\n30\nn\n"

      result =
        capture_io(user_input, fn ->
          {:ok, field_agent} = Agent.start(fn -> 5 end)
          map = SendApplication.do_gather_extra_info(field_agent, %{})
          Agent.stop(field_agent)
          assert map == %{"age" => "30"}
        end)

      # The output should contain the “Would you like to add an extra field?” prompt at least once
      assert result =~ "Would you like to add an extra field? (y/n):"
    end

    test "stops immediately if user says 'n' first" do
      user_input = "n\n"

      result =
        capture_io(user_input, fn ->
          {:ok, field_agent} = Agent.start(fn -> 5 end)
          map = SendApplication.do_gather_extra_info(field_agent, %{})
          Agent.stop(field_agent)
          assert map == %{}
        end)

      assert result =~ "Would you like to add an extra field? (y/n):"
    end

    test "respects the max‐fields limit (5) and stops after 5 additions" do
      # Simulate adding 5 fields (y, k1, v1, y, k2, v2, …) then automatically stops
      five_pairs =
        Enum.map(1..5, fn i ->
          ["y\n", "k#{i}\n", "v#{i}\n"]
        end)
        |> Enum.concat()
        |> Enum.concat(["y\n", "should_not_be_asked\nshould_not_be_asked\n"])

      # At the 6th prompt, remaining would be 0, so it won’t ask again
      user_input = Enum.join(five_pairs, "")

      result =
        capture_io(user_input, fn ->
          {:ok, field_agent} = Agent.start(fn -> 5 end)
          map = SendApplication.do_gather_extra_info(field_agent, %{})

          Agent.stop(field_agent)

          expected_map =
            Enum.into(1..5, %{}, fn i ->
              {"k#{i}", "v#{i}"}
            end)

          assert map == expected_map
        end)

      # Should have asked “Would you like to add an extra field?” exactly 6 times:
      # five times accepted (y), sixth time remaining == 0 → no prompt
      assert String.split(result, "Would you like to add an extra field?") |> Enum.count() == 6
    end
  end

  describe "extract_token/1" do
    test "trims quotes from a plain string" do
      raw = "\"plain-token-value\""
      assert SendApplication.extract_token(raw) == "plain-token-value"
    end
  end

  describe "get_or_fetch_token/1" do
    test "returns cached token on second invocation without HTTP call" do
      {:ok, agent} = Agent.start(fn -> "cached_token_456" end)

      assert SendApplication.get_or_fetch_token(agent) == {:ok, "cached_token_456"}

      Agent.stop(agent)
    end

    test "store and retrieve token from HTTPoison.get on first call" do
      bypass = Bypass.open()

      secret_url = "http://localhost:#{bypass.port}/secret"
      original_module = Application.get_env(:mix, :mitimes_secret_url, nil)
      Application.put_env(:mix, :mitimes_secret_url, secret_url)

      Bypass.expect(bypass, "GET", "/secret", fn conn ->
        Plug.Conn.resp(conn, 200, ~s({"token":"xyz789"}))
      end)

      {:ok, agent} = Agent.start(fn -> nil end)

      assert {:ok, "xyz789"} = SendApplication.get_or_fetch_token(agent)
      # Second call should reuse the cached value without hitting Bypass again
      assert {:ok, "xyz789"} = SendApplication.get_or_fetch_token(agent)

      Agent.stop(agent)

      if original_module, do: Application.put_env(:mix, :mitimes_secret_url, original_module)
      Bypass.down(bypass)
    end
  end

  describe "end‐to‐end submission loop (with Bypass)" do
    setup do
      bypass = Bypass.open()
      # Override both secret and apply URLs to localhost:<port>
      Application.put_env(:mix, :mitimes_secret_url, "http://localhost:#{bypass.port}/secret")
      Application.put_env(:mix, :mitimes_apply_url, "http://localhost:#{bypass.port}/apply")

      on_exit(fn ->
        Application.delete_env(:mix, :mitimes_secret_url)
        Application.delete_env(:mix, :mitimes_apply_url)
        Bypass.down(bypass)
      end)

      {:ok, bypass: bypass}
    end

    test "prompts user, fetches token, posts payload, and exits when user says 'n'", %{
      bypass: bypass
    } do
      Bypass.expect(bypass, "GET", "/secret", fn conn ->
        Plug.Conn.resp(conn, 200, ~s({"token":"mock_token"}))
      end)

      Bypass.expect(bypass, "POST", "/apply", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert body =~ "\"name\":\"Charlotte\""
        assert body =~ "\"email\":\"alice@example.com\""
        Plug.Conn.resp(conn, 201, ~s({"result":"ok"}))
      end)

      # Simulate user input, in this order:
      # - name:    "Charlotte\n"
      # - email:   "alice@example.com\n"
      # - job:     "Engineer\n"
      # - final:   "n\n"
      # - extra?:  "n\n"  (no custom fields)
      # - again?:  "n\n"  (do not submit another)
      user_input =
        Enum.join(
          [
            "Charlotte\n",
            "alice@example.com\n",
            "Engineer\n",
            "n\n",
            "n\n",
            "n\n"
          ],
          ""
        )

      output =
        capture_io(user_input, fn ->
          {:ok, token_agent} = Agent.start(fn -> nil end)
          SendApplication.do_submit_loop(token_agent)
          Agent.stop(token_agent)
        end)

      assert output =~ "→ Using token: mock_token"
      assert output =~ "→ POST returned status: 201"
      assert output =~ "{\"result\":\"ok\"}"
      assert output =~ "Goodbye!"
    end
  end
end
