sources.f: Bender.yml Bender.lock
	bender script flist-plus -t rtl -t synthesis > $@
