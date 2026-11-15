import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import touchgate

# True means the command must be gated. False means it must pass through.
CASES = [
    ("rm -rf /", True),
    ("rm -rf ./data", True),
    ("rm -rf ~", True),
    ("rmdir logs", True),
    ("unlink ./important.db", True),
    ("shred -u secrets.txt", True),
    ("srm secrets.txt", True),
    ("trash ./Documents", True),
    ("find . -delete", True),
    ("find . -name '*.log' -exec rm {} \\;", True),
    ("find /var -execdir rm {} +", True),
    ("git rm src/app.py", True),
    ("git clean -fd", True),
    ("git clean --force", True),
    ("git push --force origin main", True),
    ("git push -f", True),
    ("git push --force-with-lease", True),
    ("git push origin +main", True),
    ("git reset --hard", True),
    ("git reset --hard HEAD~3", True),
    ("rsync -a --delete ./src /backup", True),
    ('psql -c "DROP TABLE users"', True),
    ("psql -c 'TRUNCATE users'", True),
    ('psql -c "DELETE FROM users"', True),
    ('mysql -e "DELETE FROM accounts"', True),
    ('sqlite3 app.db "DROP TABLE sessions"', True),
    ("terraform destroy", True),
    ("terraform apply -destroy", True),
    ("kubectl delete pod web", True),
    ("kubectl -n prod delete deployment api", True),
    ("docker volume rm pgdata", True),
    ("docker volume remove pgdata", True),
    ("docker system prune -af", True),
    ("aws s3 rm s3://bucket/key --recursive", True),
    ("aws s3 rb s3://bucket --force", True),
    ("gcloud compute instances delete vm1", True),
    ("gcloud projects delete my-proj", True),
    ("gcloud sql instances delete prod --quiet", True),
    ("railway service delete", True),
    ("railway destroy", True),
    ("railway down", True),
    ("flyctl apps destroy myapp", True),
    ("fly volumes destroy vol_id", True),
    ("flyctl machine destroy 123", True),
    ("fly apps destroy myapp", True),
    ("heroku apps:destroy -a myapp", True),
    ("heroku pg:reset DATABASE_URL", True),
    ("heroku addons:destroy redis", True),
    ("sudo rm -rf /var/lib/data", True),
    ("sudo -u root rm -rf /data", True),
    ("xargs rm", True),
    ("xargs -I {} rm {}", True),
    ("env rm -rf ./data", True),
    ("env FOO=bar rm -rf ./data", True),
    ("sh -c 'rm -rf ./data'", True),
    ('bash -lc "rm -rf /"', True),
    ('ssh host "rm -rf /var/data"', True),
    ("ssh -p 22 host rm -rf /var/data", True),
    ("doas rm -rf /boot", True),
    ("ls && rm -rf ./data", True),
    ("rm -rf ./node_modules ./src", True),
    ("rm -rf /tmp/foo/../../etc", True),
    ("rm -rf ./src/node_modules/../../secrets", True),
    ("git -C ../other reset --hard", True),
    ("sudo sh -c 'rm -rf /opt/data'", True),
    ('echo "hello $(rm -rf /)"', True),
    ("echo $(rm -rf /)", True),
    ("rm -rf /tmp2/file", True),
    ("rm -rf ./build-artifacts", True),
    ('psql -c "DELETE FROM a; DROP TABLE b"', True),
    ("git push -uf origin main", True),
    ("find ./src -delete", True),
    ("find ./node_modules ./src -delete", True),
    ("rsync -a --delete-before ./ /prod/", True),
    ("rsync -a --delete ./node_modules/ user@host:/data/", True),
    ("nohup rm -rf ./data", True),
    ("time rm -rf ./data", True),
    ("command rm -rf ./src", True),
    ("echo 'DROP TABLE users' | psql", True),
    ("mariadb -e 'DROP DATABASE prod'", True),
    ("rm -rf ./data >/dev/null", True),
    ("rm -rf ./build/../src", True),
    ("psql <<EOF\nDROP TABLE users;\nEOF", True),
    ("psql <<'SQL'\nDELETE FROM accounts;\nSQL", True),
    ("mysql <<SQL\nTRUNCATE users;\nSQL", True),
    ('bash -lc "psql -c \'DROP TABLE users\'"', True),
    ('psql -c "delete from users"', True),
    ("kubectl delete -f prod.yaml", True),
    ("aws --profile prod s3 rm s3://bucket/key", True),
    ("docker --context remote system prune", True),
    ("git clean -xf", True),
    ("find . -ok rm {} \\;", True),
    ("ls", False),
    ("grep 'rm -rf' notes.txt", False),
    ("echo DROP TABLE users", False),
    ("echo 'DROP TABLE users'", False),
    ('echo "rm -rf /"', False),
    ("echo '$(rm -rf /)'", False),
    ("git rm --cached file.txt", False),
    ("git rm -r --cached src/vendor", False),
    ("rm -rf ./node_modules", False),
    ("rm -rf node_modules/pkg", False),
    ("rm -rf ./src/node_modules/pkg", False),
    ("rm -rf ./dist", False),
    ("rm -rf build", False),
    ("rm -rf .next", False),
    ("rm -rf __pycache__", False),
    ("rm -rf /tmp/foo", False),
    ("rm -rf /tmp", False),
    ("rm -rf /private/tmp/foo", False),
    ("rm -rf /tmp/foo 2>/dev/null", False),
    ("git status", False),
    ("git push origin main", False),
    ("git push -u origin HEAD", False),
    ("git push --tags", False),
    ("git reset --soft HEAD~1", False),
    ("git reset HEAD", False),
    ("git clean -n", False),
    ("git clean --dry-run", False),
    ("git clean -fd -- node_modules", False),
    ("git rm node_modules/pkg", False),
    ('psql -c "SELECT 1"', False),
    ('psql -c "DELETE FROM users WHERE id = 1"', False),
    ("terraform plan", False),
    ("terraform apply", False),
    ("kubectl get pods", False),
    ("kubectl apply -f deploy.yaml", False),
    ("kubectl delete --help", False),
    ("docker ps", False),
    ("docker rm container_id", False),
    ("docker volume ls", False),
    ("docker system df", False),
    ("echo docker volume rm data", False),
    ("aws s3 cp file s3://bucket/key", False),
    ("aws s3 ls", False),
    ("gcloud compute instances list", False),
    ("railway up", False),
    ("flyctl status", False),
    ("heroku logs", False),
    ("heroku apps", False),
    ("cat README.md", False),
    ('python3 -c "import os; os.remove(\'x\')"', False),
    ("find . -name '*.py' -print", False),
    ("find ./node_modules -delete", False),
    ("rsync -a ./src /backup", False),
    ("rsync -a --delete ./node_modules/ /tmp/nm/", False),
    ("pwd", False),
    ("unlink /tmp/old.sock", False),
    ('ssh host "ls"', False),
    ("sudo ls", False),
    ('sqlite3 app.db "SELECT * FROM t"', False),
    ('mysql -e "SELECT 1"', False),
    ("rm --help", False),
    ("sqlite3 app.db <<EOF\nSELECT 1;\nEOF", False),
    ("git rm --cached", False),
    ("true", False),
]


class DetectTests(unittest.TestCase):
    def test_case_count(self):
        self.assertGreaterEqual(len(CASES), 40)

    def test_detection_table(self):
        config = touchgate.default_config()
        for command, gated in CASES:
            with self.subTest(command=command):
                found = touchgate.describe(command, config)
                if gated:
                    self.assertIsNotNone(found, command)
                else:
                    self.assertIsNone(found, found)

    def test_extra_pattern_gates_allowlisted_rm(self):
        config = touchgate.default_config()
        config["extra_patterns"] = [r"\brm\b"]
        self.assertIsNotNone(touchgate.describe("rm -rf ./node_modules", config))

    def test_empty_allowlist_gates_node_modules(self):
        config = {"allow_paths": [], "extra_patterns": []}
        self.assertIsNotNone(touchgate.describe("rm -rf ./node_modules", config))

    def test_invalid_extra_pattern_is_ignored(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "touchgate.json")
            with open(path, "w", encoding="utf-8") as handle:
                handle.write('{"extra_patterns": ["(", "mkfs"]}')
            config = touchgate.load_config(path)
            self.assertEqual(config["extra_patterns"], ["mkfs"])
            self.assertIsNotNone(touchgate.describe("mkfs /dev/disk2", config))
            self.assertIsNone(touchgate.describe("ls", config))

    def test_broken_config_keeps_default_allowlist(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "touchgate.json")
            with open(path, "w", encoding="utf-8") as handle:
                handle.write("{not json")
            config = touchgate.load_config(path)
            self.assertIn("node_modules", config["allow_paths"])
            self.assertIsNone(touchgate.describe("rm -rf ./node_modules", config))

    def test_missing_config_uses_defaults(self):
        config = touchgate.load_config(os.path.join(tempfile.gettempdir(), "touchgate-missing-config.json"))
        self.assertEqual(config["allow_paths"], list(touchgate.DEFAULT_ALLOW_PATHS))
        self.assertEqual(config["extra_patterns"], [])


if __name__ == "__main__":
    unittest.main()
