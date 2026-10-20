import pf.Cmd
import pf.Env
import pf.OsStr
import pf.Path
import pf.System
import Checkout
import Run
import Toolchain

## The site is a roux app (site/), built as the roux competitor is, on
## roux's platform and tools as the toolchain readies them: `roux build`
## types the queries, writes each template's contract module, compiles the
## templates and, with roc, the app, and links one static binary; then the
## app's expects run.
Site :: [].{
	## out/bin/dragrace-site.
	binary : Str -> Str
	binary = |root| "${Checkout.bin(root)}/dragrace-site"

	## The optimized build and the site's tests.
	build! : Str, Toolchain.Ready => Try({}, [Failed(Str), Interrupted])
	build! = |root, ready| {
		# roux attaches the templates to the binary roc wrote: in a fresh
		# checkout, with no out/bin yet, there is none (AttachFailed).
		Path.utf8(Checkout.bin(root)).create_all!() ? |PathErr(err, _)| Failed("out/bin: ${err.to_str()}")
		dir = "${root}/site"
		roux = "${ready.tools.roux}/zig-out/bin/roux"
		Run.run!(dir, [], [roux, "build", "--roc=${ready.tools.roc}", "--output=${Site.binary(root)}", "main.roc"])?
		Run.run!(dir, [], [ready.tools.roc, "test", "main.roc"])
	}

	## `roux dev` on site/ in this process's place, so its signals are its
	## own: a template's edit shows in milliseconds, Roc or a query rebuilds.
	dev! : Str, Toolchain.Ready, U64 => Try({}, [Failed(Str), Interrupted])
	dev! = |root, ready, port| {
		roux = "${ready.tools.roux}/zig-out/bin/roux"
		Env.set_cwd!(Path.utf8("${root}/site")) ? |_| Failed("site/: cannot go there")
		Run.log!("dev: http://127.0.0.1:${port.to_str()}/; editing site/ rebuilds")
		args = ["dev", "--roc=${ready.tools.roc}", "--port=${port.to_str()}", "main.roc"].map(OsStr.from_str)
		replaced =
			match System.target!().os() {
				Linux(os) => Cmd.exec!(os.unix(), Path.utf8(roux), args)
				MacOS(os) => Cmd.exec!(os.unix(), Path.utf8(roux), args)
				Windows(_) => return Err(Failed("site dev: Linux or macOS"))
			}
		match replaced {
			Ok(never) => never
			Err(Interrupted) => Err(Interrupted)
			Err(CmdErr(err)) => Err(Failed("roux dev: ${err.to_str()}"))
		}
	}
}
