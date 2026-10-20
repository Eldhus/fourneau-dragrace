import pf.Env
import pf.OsStr
import Run

## The owner's secrets for self-hosting live in their keyring (secret-tool,
## service fourneau-dragrace), never in a file or on a command line: the
## racer and manual tokens, made here when missing. They travel to a host
## over SSH, on standard input.
Keyring :: [].{
	## A secret; a missing one is an error.
	lookup! : Str => Try(Str, [Failed(Str), Interrupted])
	lookup! = |name| {
		found =
			match Run.output!("", ["secret-tool", "lookup", "service", service, "name", name]) {
				Ok(secret) => secret
				Err(Interrupted) => return Err(Interrupted)
				Err(Failed(_)) => ""
			}
		if found == "" {
			Err(Failed("no ${name} in the keyring (secret-tool lookup service ${service} name ${name})"))
		} else {
			Ok(found)
		}
	}

	## A token, made and stored if the keyring has none.
	token! : Str => Try(Str, [Failed(Str), Interrupted])
	token! = |name|
		match Keyring.lookup!(name) {
			Ok(token) => Ok(token)
			Err(Interrupted) => Err(Interrupted)
			Err(Failed(_)) => {
				token = Run.random_token!()?
				_ = Run.with_input!("", ["secret-tool", "store", "--label", "${service}-${name}", "service", service, "name", name], token.to_utf8())?
				Ok(token)
			}
		}

	## The owner's DigitalOcean token: DIGITALOCEAN_TOKEN, or the keyring's.
	digitalocean! : () => Try(Str, [Failed(Str), Interrupted])
	digitalocean! = || {
		from_env = (Env.var_str!(OsStr.from_str("DIGITALOCEAN_TOKEN")) ?? "").trim()
		if from_env != "" {
			return Ok(from_env)
		}
		match Run.output!("", ["secret-tool", "lookup", "service", "digitalocean", "name", "fourneau-dragrace"]) {
			Ok(token) if token != "" => Ok(token)
			Err(Interrupted) => Err(Interrupted)
			_ => Err(Failed("no DIGITALOCEAN_TOKEN and none in the keyring (secret-tool lookup service digitalocean name fourneau-dragrace)"))
		}
	}
}

service : Str
service = "fourneau-dragrace"
