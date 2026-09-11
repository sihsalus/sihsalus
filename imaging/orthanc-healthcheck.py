"""Check Orthanc and its DICOMweb plugin without querying patient resources."""

from contextlib import closing
import http.client
import sys


def is_ready():
    try:
        with closing(http.client.HTTPConnection("127.0.0.1", 8042, timeout=3)) as connection:
            for endpoint in ("/system", "/plugins/dicom-web"):
                connection.request("GET", endpoint)
                response = connection.getresponse()
                if response.status != 200:
                    return False
                response.read()
        return True
    except (OSError, http.client.HTTPException):
        return False


if __name__ == "__main__":
    sys.exit(0 if is_ready() else 1)
