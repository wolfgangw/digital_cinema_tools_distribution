## Digital Cinema Tools Distribution

Please see [Digital Cinema Tools Distribution](https://github.com/wolfgangw/digital_cinema_tools_distribution/wiki) for an introduction and check out the [Setup](https://github.com/wolfgangw/digital_cinema_tools_distribution/wiki/Setup) script.

The DockerFile will install digital_cinema_tools_distribution, and to run it, start it in Interactive mode. IE:
```bash
docker run --rm -ti -v /Volumes:/Volumes jaminmc/digital_cinema_tools_distribution
```

On a Mac, mounting `-v /Volumes:/Volumes` allows access to the drives that are not the OS drive to be able to check a DCP by just pasting `dcp_inspect [options] ` and drag the folder you want to check into the terminal.

I also have /linux/arm64 compiled as container images.

[Wolfgang Woehl](https://github.com/wolfgangw) 2012-2013
