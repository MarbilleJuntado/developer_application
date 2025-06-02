defmodule Mix.Tasks.Send.Application do
  use Mix.Task

  @shortdoc "Collects applicant info + up to 5 custom fields (via Agent), caches token, loops for multiple submissions with colored output."

  @moduledoc """
  mix send.application

  1. Prompts for `name` (nonempty, max 3 tries via Agent), validates `email` (format, max 3 tries via Agent),
     `job_title` (nonempty, max 3 tries), and a strict y/n for `final_attempt` (max 3 tries).
  2. Uses an Agent to track how many custom fields you can still add (initially 5).
     Each key is validated so it does not contain double‐quotes or control characters (max 3 tries per key, tracked via its own Agent).
     Each value is validated as nonempty (max 3 tries, tracked via its own Agent).
     Those pairs are bundled into the `"extra_information"` JSON object.
  3. Uses another Agent to cache the token fetched from `/careers/apply/secret`.
     If already fetched once in this run, reuses it.
  4. Performs GET (only once per run) against `https://au.mitimes.com/careers/apply/secret` to retrieve an Authorization token.
  5. Sends a POST (with that token) to `https://au.mitimes.com/careers/apply` with a JSON body containing at least:
     ```
     %{
       "name"              => ...,
       "email"             => ...,
       "job_title"         => ...,
       "final_attempt"     => true | false,
       "extra_information" => %{ optional_key1: value1, … }
     }
     ```
  6. Prints colored HTTP status and response body to the console.
  7. Prompts (max 3 tries via Agent) “Would you like to submit another application? (y/n):”.
     If yes, loops back to step 1 (reusing the cached token). If no, exits.
  """

  @email_regex ~r/^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$/
  @json_key_regex ~r/^[^\x00-\x1F"]+$/u
  @max_extra_fields 5
  @max_attempts 3
  @secret_url "https://au.mitimes.com/careers/apply/secret"
  @apply_url "https://au.mitimes.com/careers/apply"

  def run(_args) do
    # 1) Ensure HTTPoison and Jason are started
    {:ok, _} = Application.ensure_all_started(:httpoison)
    {:ok, _} = Application.ensure_all_started(:jason)

    # 2) Start an Agent to cache the token (initially nil)
    {:ok, token_agent} = Agent.start(fn -> nil end)

    # 3) Enter submission loop
    do_submit_loop(token_agent)

    # 4) Stop the token cache Agent when done
    Agent.stop(token_agent)
  end

  # ─── Submission loop ──────────────────────────────────────────────────────────

  defp do_submit_loop(token_agent) do
    # Prompt for fields
    name = prompt_nonempty("Enter your full name: ")
    email = prompt_email("Enter your email address: ")
    job_title = prompt_nonempty("Enter the job title you are applying for: ")
    final_attempt = prompt_yes_no("Is this your final attempt? (y/n): ")

    # Gather up to @max_extra_fields custom key/value pairs
    IO.puts(
      IO.ANSI.yellow() <>
        "\nNow you may add up to #{@max_extra_fields} custom fields under \"extra_information\"." <>
        IO.ANSI.reset()
    )

    {:ok, field_agent} = Agent.start(fn -> @max_extra_fields end)
    extra_info_map = do_gather_extra_info(field_agent, %{})
    Agent.stop(field_agent)

    # Fetch or reuse cached token
    case get_or_fetch_token(token_agent) do
      {:ok, token} ->
        Mix.shell().info(IO.ANSI.cyan() <> "\n→ Using token: #{token}" <> IO.ANSI.reset())

        # Build payload
        payload_map = %{
          "name" => name,
          "email" => email,
          "job_title" => job_title,
          "final_attempt" => final_attempt,
          "extra_information" => extra_info_map
        }

        {:ok, payload_json} = Jason.encode(payload_map)

        # POST to /careers/apply
        headers = [
          {"Content-Type", "application/json"},
          {"Authorization", token}
        ]

        Mix.shell().info(
          IO.ANSI.cyan() <> "\nSubmitting application to #{@apply_url} ..." <> IO.ANSI.reset()
        )

        case HTTPoison.post(@apply_url, payload_json, headers, recv_timeout: 10_000) do
          {:ok, %HTTPoison.Response{status_code: status, body: resp_body}} ->
            IO.puts(IO.ANSI.green() <> "→ POST returned status: #{status}" <> IO.ANSI.reset())
            IO.puts(IO.ANSI.green() <> "→ Response body:" <> IO.ANSI.reset())
            IO.puts(resp_body)

          {:error, %HTTPoison.Error{reason: reason}} ->
            Mix.shell().error(
              IO.ANSI.red() <> "Error while POSTing: #{inspect(reason)}" <> IO.ANSI.reset()
            )
        end

      {:error, {:http_error, sc, body}} ->
        Mix.shell().error(
          IO.ANSI.red() <>
            "Failed to fetch token. HTTP status: #{sc}\nBody:\n#{body}" <> IO.ANSI.reset()
        )

      {:error, {:httpoison_error, reason}} ->
        Mix.shell().error(
          IO.ANSI.red() <> "HTTP GET error: #{inspect(reason)}" <> IO.ANSI.reset()
        )
    end

    # After attempt, ask if user wants to submit another (max 3 tries)
    # blank line before prompt
    IO.puts("")

    if prompt_yes_no("Would you like to submit another application? (y/n): ") do
      IO.puts(IO.ANSI.yellow() <> "\n=== Starting next submission ===\n" <> IO.ANSI.reset())
      do_submit_loop(token_agent)
    else
      IO.puts(IO.ANSI.cyan() <> "\nGoodbye!" <> IO.ANSI.reset())
      :ok
    end
  end

  # ─── Token caching via Agent ──────────────────────────────────────────────────

  defp get_or_fetch_token(agent) do
    case Agent.get(agent, & &1) do
      nil ->
        Mix.shell().info(
          IO.ANSI.cyan() <>
            "\nFetching Authorization token from #{@secret_url} ..." <> IO.ANSI.reset()
        )

        case HTTPoison.get(@secret_url, [], recv_timeout: 10_000) do
          {:ok, %HTTPoison.Response{status_code: 200, body: body}} ->
            token = extract_token(body)
            Agent.update(agent, fn _ -> token end)
            {:ok, token}

          {:ok, %HTTPoison.Response{status_code: sc, body: resp_body}} ->
            {:error, {:http_error, sc, resp_body}}

          {:error, %HTTPoison.Error{reason: reason}} ->
            {:error, {:httpoison_error, reason}}
        end

      cached_token ->
        {:ok, cached_token}
    end
  end

  # ─── Gathering extra_information via Agent ────────────────────────────────────

  defp do_gather_extra_info(field_agent, acc_map) do
    remaining = Agent.get(field_agent, & &1)

    cond do
      remaining <= 0 ->
        acc_map

      prompt_yes_no("Would you like to add an extra field? (y/n): ") ->
        field_name = prompt_valid_json_key("  Enter field name (no quotes or control chars): ")
        field_value = prompt_nonempty("  Enter value for #{field_name}: ")

        Agent.update(field_agent, &(&1 - 1))
        new_map = Map.put(acc_map, field_name, field_value)
        do_gather_extra_info(field_agent, new_map)

      true ->
        acc_map
    end
  end

  # ─── Prompt helpers with Agent tracking ────────────────────────────────────────

  # Prompt until nonempty, max @max_attempts tries (using an Agent to track attempts)
  defp prompt_nonempty(prompt_text) do
    {:ok, agent} = Agent.start(fn -> @max_attempts end)
    do_prompt_nonempty(prompt_text, agent)
  end

  defp do_prompt_nonempty(prompt_text, agent) do
    attempts_left = Agent.get(agent, & &1)

    if attempts_left <= 0 do
      Agent.stop(agent)

      Mix.raise(
        IO.ANSI.red() <>
          "Too many invalid attempts for required field. Aborting." <> IO.ANSI.reset()
      )
    else
      IO.write(IO.ANSI.yellow() <> prompt_text <> IO.ANSI.reset())
      input = IO.gets("") |> handle_gets()

      if input == "" do
        Agent.update(agent, &(&1 - 1))
        new_attempts = Agent.get(agent, & &1)

        IO.puts(
          IO.ANSI.red() <>
            "  → Cannot be empty. You have #{new_attempts} attempt(s) left." <> IO.ANSI.reset()
        )

        do_prompt_nonempty(prompt_text, agent)
      else
        Agent.stop(agent)
        input
      end
    end
  end

  # Prompt until a valid email format, max @max_attempts tries (using Agent)
  defp prompt_email(prompt_text) do
    {:ok, agent} = Agent.start(fn -> @max_attempts end)
    do_prompt_email(prompt_text, agent)
  end

  defp do_prompt_email(prompt_text, agent) do
    attempts_left = Agent.get(agent, & &1)

    if attempts_left <= 0 do
      Agent.stop(agent)
      Mix.raise(IO.ANSI.red() <> "Too many invalid email attempts. Aborting." <> IO.ANSI.reset())
    else
      IO.write(IO.ANSI.yellow() <> prompt_text <> IO.ANSI.reset())
      input = IO.gets("") |> handle_gets()

      if Regex.match?(@email_regex, input) do
        Agent.stop(agent)
        input
      else
        Agent.update(agent, &(&1 - 1))
        new_attempts = Agent.get(agent, & &1)

        IO.puts(
          IO.ANSI.red() <>
            "  → Invalid email format. You have #{new_attempts} attempt(s) left." <>
            IO.ANSI.reset()
        )

        do_prompt_email(prompt_text, agent)
      end
    end
  end

  # Prompt a strict y/n; returns true for "y", false for "n"; max @max_attempts tries (using Agent)
  defp prompt_yes_no(prompt_text) do
    {:ok, agent} = Agent.start(fn -> @max_attempts end)
    do_prompt_yes_no(prompt_text, agent)
  end

  defp do_prompt_yes_no(prompt_text, agent) do
    attempts_left = Agent.get(agent, & &1)

    if attempts_left <= 0 do
      Agent.stop(agent)
      Mix.raise(IO.ANSI.red() <> "Too many invalid y/n attempts. Aborting." <> IO.ANSI.reset())
    else
      IO.write(IO.ANSI.yellow() <> prompt_text <> IO.ANSI.reset())
      answer = IO.gets("") |> handle_gets() |> String.downcase()

      case answer do
        "y" ->
          Agent.stop(agent)
          true

        "n" ->
          Agent.stop(agent)
          false

        _ ->
          Agent.update(agent, &(&1 - 1))
          new_attempts = Agent.get(agent, & &1)

          IO.puts(
            IO.ANSI.red() <>
              "  → Please type \"y\" or \"n\". You have #{new_attempts} attempt(s) left." <>
              IO.ANSI.reset()
          )

          do_prompt_yes_no(prompt_text, agent)
      end
    end
  end

  # Prompt until a valid JSON key (no quotes, no control characters, nonempty), max @max_attempts tries (using Agent)
  defp prompt_valid_json_key(prompt_text) do
    {:ok, agent} = Agent.start(fn -> @max_attempts end)
    do_prompt_valid_json_key(prompt_text, agent)
  end

  defp do_prompt_valid_json_key(prompt_text, agent) do
    attempts_left = Agent.get(agent, & &1)

    if attempts_left <= 0 do
      Agent.stop(agent)

      Mix.raise(
        IO.ANSI.red() <> "Too many invalid attempts for JSON key. Aborting." <> IO.ANSI.reset()
      )
    else
      IO.write(IO.ANSI.yellow() <> prompt_text <> IO.ANSI.reset())
      input = IO.gets("") |> handle_gets()

      cond do
        input == "" ->
          Agent.update(agent, &(&1 - 1))
          new_attempts = Agent.get(agent, & &1)

          IO.puts(
            IO.ANSI.red() <>
              "    → Key cannot be empty. You have #{new_attempts} attempt(s) left." <>
              IO.ANSI.reset()
          )

          do_prompt_valid_json_key(prompt_text, agent)

        not Regex.match?(@json_key_regex, input) ->
          Agent.update(agent, &(&1 - 1))
          new_attempts = Agent.get(agent, & &1)

          IO.puts(
            IO.ANSI.red() <>
              "    → Invalid key. Must not contain control chars or double‐quotes. You have #{new_attempts} attempt(s) left." <>
              IO.ANSI.reset()
          )

          do_prompt_valid_json_key(prompt_text, agent)

        true ->
          Agent.stop(agent)
          input
      end
    end
  end

  # Trim newline or return empty string if nil
  defp handle_gets(nil), do: ""
  defp handle_gets(str), do: String.trim(str)

  # Try to decode JSON; if it’s {"token":"…"}, pull out the value; otherwise trim quotes.
  defp extract_token(body) do
    case Jason.decode(body) do
      {:ok, %{"token" => tok}} ->
        tok

      {:ok, body} ->
        Mix.shell().error(
          IO.ANSI.red() <>
            "Warning: /secret returned JSON without a \"token\" key. Using raw body." <>
            IO.ANSI.reset()
        )

        String.trim(body)

      {:error, _} ->
        # Not JSON → assume raw text with quotes
        String.trim(body)
    end
  end
end
