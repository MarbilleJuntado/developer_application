## Developer Application CLI

A Mix task in Elixir that interactively collects applicant information, caches a token, and submits it to a remote endpoint. It supports retry logic (via Agents), custom JSON fields, and colored console output.

### Features

1. Prompts for `name` (nonempty, max 3 tries via Agent), validates `email` (format, max 3 tries via Agent),
   `job_title` (nonempty, max 3 tries), and a strict y/n for `final_attempt` (max 3 tries).
2. Uses an Agent to track how many custom fields you can still add (initially 5).
   Each key is validated so it does not contain double‐quotes or control characters (max 3 tries per key, tracked via its own Agent).
   Each value is validated as nonempty (max 3 tries, tracked via its own Agent).
   Those pairs are bundled into the `"extra_information"` JSON object.
3. Uses another Agent to cache the token fetched from `/careers/apply/secret`.
   If already fetched once in this run, reuses it.
4. Performs GET (only once per run) against the URL returned by `fetch_secret_url/0` to retrieve an Authorization token.
5. Sends a POST (with that token) to `/careers/apply` with a JSON body containing at least:
   ```elixir
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

### Prerequisites
* [Docker](https://docs.docker.com/get-docker/) installed on your system.
* `docker compose (v2)` must be available.

### Installation
1. Clone this repository:
   ```bash
   git clone https://github.com/MarbilleJuntado/developer_application.git
   cd developer_application
   ```
2. ```bash
   docker compose build
   ```

### Usage
```bash
docker compose run --rm developer_application
```

### Running tests
```bash
docker compose run --rm test
```
