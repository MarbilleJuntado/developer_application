defmodule Mix.Tasks.Send.Application do
  use Mix.Task

  @moduledoc """
  Collects applicant info + up to 5 custom fields (via Agent), caches token, loops for multiple submissions with colored output.
  """

  @email_regex ~r/^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$/
  @json_key_regex ~r/^[^\x00-\x1F"]+$/u
  @max_extra_fields 5
  @max_attempts 3

  @default_secret_url "https://au.mitimes.com/careers/apply/secret"
  @default_apply_url "https://au.mitimes.com/careers/apply"

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

  # Submission loop

  def do_submit_loop(token_agent) do
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

        apply_url = fetch_apply_url()

        Mix.shell().info(
          IO.ANSI.cyan() <> "\nSubmitting application to #{apply_url} ..." <> IO.ANSI.reset()
        )

        case HTTPoison.post(apply_url, payload_json, headers, recv_timeout: 10_000) do
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
    IO.puts("")

    if prompt_yes_no("Would you like to submit another application? (y/n): ") do
      IO.puts(IO.ANSI.yellow() <> "\n=== Starting next submission ===\n" <> IO.ANSI.reset())
      do_submit_loop(token_agent)
    else
      IO.puts(IO.ANSI.cyan() <> "\nGoodbye!" <> IO.ANSI.reset())
      :ok
    end
  end

  defp fetch_apply_url do
    Application.get_env(:mix, :mitimes_apply_url, @default_apply_url)
  end

  # Token caching via Agent

  defp fetch_secret_url do
    Application.get_env(:mix, :mitimes_secret_url, @default_secret_url)
  end

  def get_or_fetch_token(agent) do
    case Agent.get(agent, & &1) do
      nil ->
        secret_url = fetch_secret_url()

        Mix.shell().info(
          IO.ANSI.cyan() <>
            "\nFetching Authorization token from #{secret_url} ..." <> IO.ANSI.reset()
        )

        case HTTPoison.get(secret_url, [], recv_timeout: 10_000) do
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

  # Gathering extra_information via Agent

  def do_gather_extra_info(field_agent, acc_map) do
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

  # Prompt helpers with Agent tracking

  def prompt_nonempty(prompt_text) do
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

  def prompt_email(prompt_text) do
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

  def prompt_yes_no(prompt_text) do
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

  def prompt_valid_json_key(prompt_text) do
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

  defp handle_gets(nil), do: ""
  defp handle_gets(str), do: String.trim(str)

  def extract_token(body) do
    case Jason.decode(body) do
      {:ok, %{"token" => tok}} ->
        tok

      {:ok, body} ->
        String.trim(body)

      {:error, _} ->
        String.trim(body)
    end
  end
end
