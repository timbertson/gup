{ stdenv, fetchurl, 
	ocaml, findlib
}:
stdenv.mkDerivation {
	name = "extunix-0.1.2";
	src = fetchurl {
		url = "https://github.com/ygrek/extunix/archive/v0.1.2.tar.gz";
		sha256="0wv8mf4aspcvapdh23ykrqy6xhjmg5qz13akss426hh3vkx7njny";
	};
	buildInputs = [
		ocaml findlib
	];
	createFindlibDestdir = true;
}
