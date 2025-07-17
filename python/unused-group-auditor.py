import grp
import pwd

def main():
    groups = grp.getgrall()
    user_groups = {g: False for g in [g.gr_name for g in groups]}
    for p in pwd.getpwall():
        for g in p.pw_gid, *[grp.getgrnam(gr).gr_gid for gr in p.pw_name.split() if gr in user_groups]:
            try:
                group_name = grp.getgrgid(g).gr_name
                user_groups[group_name] = True
            except KeyError:
                continue
    for group, used in user_groups.items():
        if not used:
            print(f"Unused group: {group}")

if __name__ == "__main__":
    main()